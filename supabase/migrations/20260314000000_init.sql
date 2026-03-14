-- ============================================================
-- LYRA DATABASE SCHEMA (v2 — Multi-Vector Engine)
-- ============================================================

-- PostGIS: lets us ask "who's within 100 meters?"
CREATE EXTENSION IF NOT EXISTS postgis;

-- pgvector: lets us compare personality fingerprints
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- USERS — identity and preferences
-- ============================================================
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  name TEXT NOT NULL,
  age INTEGER,
  gender TEXT[],              -- Using array for flexibility (e.g. ['man', 'non-binary'])
  show_me TEXT[],             -- Who they want to see (e.g. ['woman', 'non-binary'])
  photo_url TEXT,
  expo_push_token TEXT,
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- PROFILES — the high-definition personality fingerprint
-- ============================================================
CREATE TABLE profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE,
  transcript JSONB,           -- The full interview history
  summary TEXT,               -- 2-3 sentence bio
  traits JSONB,               -- Raw trait data from Claude
  
  -- The 8 Vector Dimensions (512-dim each)
  v_big_five VECTOR(512),
  v_values VECTOR(512),
  v_interests VECTOR(512),
  v_energy VECTOR(512),
  v_communication VECTOR(512),
  v_relationship VECTOR(512),
  v_compatibility VECTOR(512),
  v_keywords VECTOR(512),
  
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- LOCATIONS — where you are right now
-- ============================================================
CREATE TABLE locations (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  location GEOGRAPHY(POINT, 4326) NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- MATCHES — when two people are connected
-- ============================================================
CREATE TABLE matches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a UUID REFERENCES users(id),
  user_b UUID REFERENCES users(id),
  score FLOAT,              -- Weighted similarity score (0 to 1)
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'met')),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- INTERACTIONS — history (prevents re-matching)
-- ============================================================
CREATE TABLE interactions (
  id BIGSERIAL PRIMARY KEY,
  actor_id UUID REFERENCES users(id),
  target_id UUID REFERENCES users(id),
  action TEXT CHECK (action IN ('liked', 'passed', 'reported')),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- INDEXES — optimized for geography and high-dim vectors
-- ============================================================
CREATE INDEX idx_locations_geo ON locations USING GIST(location);
CREATE INDEX idx_profiles_v_values ON profiles USING hnsw(v_values vector_cosine_ops);
CREATE INDEX idx_profiles_v_big_five ON profiles USING hnsw(v_big_five vector_cosine_ops);
CREATE UNIQUE INDEX idx_interactions_pair ON interactions(actor_id, target_id);

-- ============================================================
-- ROW LEVEL SECURITY (RLS)
-- ============================================================
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations ENABLE ROW LEVEL SECURITY;
ALTER TABLE matches ENABLE ROW LEVEL SECURITY;

-- Users can manage their own data
CREATE POLICY "Users can manage own record" ON users ALL USING (auth.uid() = auth_id);
CREATE POLICY "Users can manage own location" ON locations ALL USING (auth.uid() IN (SELECT auth_id FROM users WHERE id = user_id));
CREATE POLICY "Users can view own profile" ON profiles SELECT USING (auth.uid() IN (SELECT auth_id FROM users WHERE id = user_id));

-- The Edge Function (via service_role) will handle inserts to profiles and matches
-- but we allow users to read their matches
CREATE POLICY "Users can view own matches" ON matches SELECT USING (
  auth.uid() IN (SELECT auth_id FROM users WHERE id IN (user_a, user_b))
);

-- ============================================================
-- REALTIME
-- ============================================================
ALTER PUBLICATION supabase_realtime ADD TABLE matches, locations;

-- ============================================================
-- THE MATCHING ENGINE (Trigger)
--
-- Calculates a weighted similarity across 8 personality vectors.
-- Weights:
-- Values: 35% | Big Five: 25% | Interests: 15% | Others: 5% each
-- ============================================================
CREATE OR REPLACE FUNCTION trigger_match_check()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  me RECORD;
  my_p RECORD;
BEGIN
  -- 1. Look up the user who just moved
  SELECT * INTO me FROM users WHERE id = NEW.user_id;
  SELECT * INTO my_p FROM profiles WHERE user_id = NEW.user_id;

  -- Skip if they haven't completed the interview
  IF my_p.v_values IS NULL THEN RETURN NEW; END IF;

  -- 2. Find the most compatible person nearby
  INSERT INTO matches (user_a, user_b, score)
  SELECT
    NEW.user_id,
    u.id,
    (
      (1 - (my_p.v_values <=> p.v_values)) * 0.35 +
      (1 - (my_p.v_big_five <=> p.v_big_five)) * 0.25 +
      (1 - (my_p.v_interests <=> p.v_interests)) * 0.15 +
      (1 - (my_p.v_energy <=> p.v_energy)) * 0.05 +
      (1 - (my_p.v_communication <=> p.v_communication)) * 0.05 +
      (1 - (my_p.v_relationship <=> p.v_relationship)) * 0.05 +
      (1 - (my_p.v_compatibility <=> p.v_compatibility)) * 0.05 +
      (1 - (my_p.v_keywords <=> p.v_keywords)) * 0.05
    ) as total_score
  FROM users u
  JOIN locations l ON l.user_id = u.id
  JOIN profiles p ON p.user_id = u.id
  WHERE u.id != NEW.user_id                           -- Not me
    AND u.is_active = true                             -- Still active
    AND ST_DWithin(l.location, NEW.location, 100)      -- Within 100m
    AND p.v_values IS NOT NULL                         -- Has vectors
    
    -- GENDER MATCHING (Array Overlap Logic)
    -- "Does my gender exist in their show_me, AND does their gender exist in my show_me?"
    AND me.gender && u.show_me 
    AND u.gender && me.show_me
    
    -- HISTORY & COOLDOWN
    AND NOT EXISTS (SELECT 1 FROM interactions i WHERE i.actor_id = me.id AND i.target_id = u.id)
    AND NOT EXISTS (SELECT 1 FROM matches m WHERE (m.user_a = me.id OR m.user_b = me.id) AND m.status = 'pending')
    
  ORDER BY 1 - (my_p.v_values <=> p.v_values) ASC -- Quick rough sort by values
  LIMIT 1
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

CREATE TRIGGER on_location_update
AFTER INSERT OR UPDATE ON locations
FOR EACH ROW
EXECUTE FUNCTION trigger_match_check();
