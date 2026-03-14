-- ============================================================
-- LYRA DATABASE SCHEMA
--
-- 5 tables, that's the whole app.
-- ============================================================

-- PostGIS: lets us ask "who's within 100 meters?"
CREATE EXTENSION IF NOT EXISTS postgis;

-- pgvector: lets us compare personality fingerprints
CREATE EXTENSION IF NOT EXISTS vector;

-- ============================================================
-- USERS — who you are (from onboarding)
-- ============================================================
CREATE TABLE users (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  auth_id UUID REFERENCES auth.users(id) ON DELETE CASCADE UNIQUE,
  name TEXT NOT NULL,
  age INTEGER,
  gender TEXT,              -- plain text, no constraints
  show_me TEXT,             -- who they want to see
  photo_url TEXT,
  expo_push_token TEXT,     -- for sending push notifications
  is_active BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- PROFILES — what the AI learned about you (from interview)
--
-- transcript: the full chat history as JSON
-- summary: Claude's 2-3 sentence description of you
-- traits: everything Claude figured out (Big Five, values,
--         interests, etc.) stored as one JSON blob
-- embedding: 512 numbers = your personality fingerprint
-- ============================================================
CREATE TABLE profiles (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID REFERENCES users(id) ON DELETE CASCADE UNIQUE,
  transcript JSONB,
  summary TEXT,
  traits JSONB,
  embedding VECTOR(512),
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- LOCATIONS — where you are right now
--
-- GEOGRAPHY type means distances are in meters (not degrees).
-- One row per user, updated every time GPS reports.
-- ============================================================
CREATE TABLE locations (
  user_id UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  location GEOGRAPHY(POINT, 4326) NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- MATCHES — when two people are connected
--
-- Created automatically by the match trigger (see below).
-- status: pending → approved → met (or rejected)
-- ============================================================
CREATE TABLE matches (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a UUID REFERENCES users(id),
  user_b UUID REFERENCES users(id),
  score FLOAT,              -- compatibility score (0 to 1)
  status TEXT DEFAULT 'pending',
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- INTERACTIONS — history, so you never see the same person twice
-- ============================================================
CREATE TABLE interactions (
  id BIGSERIAL PRIMARY KEY,
  actor_id UUID REFERENCES users(id),
  target_id UUID REFERENCES users(id),
  action TEXT,              -- liked, passed, reported
  created_at TIMESTAMPTZ DEFAULT now()
);

-- ============================================================
-- INDEXES — make queries fast
--
-- GiST index: makes "find everyone within 100m" instant
-- HNSW index: makes "find similar personalities" instant
-- ============================================================
CREATE INDEX idx_locations_geo ON locations USING GIST(location);
CREATE INDEX idx_profiles_embedding ON profiles USING hnsw(embedding vector_cosine_ops);
CREATE UNIQUE INDEX idx_interactions_pair ON interactions(actor_id, target_id);

-- ============================================================
-- REALTIME — tell Supabase to broadcast changes to these tables
-- over WebSocket so phones get instant updates
-- ============================================================
ALTER PUBLICATION supabase_realtime ADD TABLE matches, locations;

-- ============================================================
-- MATCH TRIGGER
--
-- This is the magic. Every time a location updates, Postgres
-- automatically checks: "is anyone compatible within 100m?"
-- If yes, it creates a match. No server code needed.
--
-- The chain: location update → trigger → match created →
--            webhook → Edge Function → push notification
-- ============================================================
CREATE OR REPLACE FUNCTION trigger_match_check()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER  -- bypasses row-level security (needs to read all users)
AS $$
DECLARE
  current_user_rec RECORD;
  current_profile RECORD;
BEGIN
  -- Look up the user who just moved
  SELECT * INTO current_user_rec FROM users WHERE id = NEW.user_id;
  SELECT * INTO current_profile FROM profiles WHERE user_id = NEW.user_id;

  -- If they haven't done the interview yet, skip
  IF current_profile.embedding IS NULL THEN RETURN NEW; END IF;

  -- Find the most compatible person within 100m and create a match
  INSERT INTO matches (user_a, user_b, score)
  SELECT
    NEW.user_id,
    u.id,
    -- Cosine similarity: 1 = identical, 0 = nothing in common
    1 - (current_profile.embedding <=> p.embedding)
  FROM users u
  JOIN locations l ON l.user_id = u.id
  JOIN profiles p ON p.user_id = u.id
  WHERE u.id != NEW.user_id                           -- not yourself
    AND u.is_active = true                             -- still active
    AND ST_DWithin(l.location, NEW.location, 100)      -- within 100 meters
    AND p.embedding IS NOT NULL                        -- completed interview
    AND u.gender = current_user_rec.show_me            -- gender preferences
    AND current_user_rec.gender = u.show_me            -- bidirectional
    AND NOT EXISTS (                                   -- never interacted before
      SELECT 1 FROM interactions i
      WHERE i.actor_id = NEW.user_id AND i.target_id = u.id
    )
    AND NOT EXISTS (                                   -- no existing match
      SELECT 1 FROM matches m
      WHERE (m.user_a = NEW.user_id AND m.user_b = u.id)
         OR (m.user_a = u.id AND m.user_b = NEW.user_id)
    )
  ORDER BY p.embedding <=> current_profile.embedding ASC  -- most compatible first
  LIMIT 1
  ON CONFLICT DO NOTHING;

  RETURN NEW;
END;
$$;

-- Wire it up: run trigger_match_check every time a location changes
CREATE TRIGGER on_location_update
AFTER INSERT OR UPDATE ON locations
FOR EACH ROW
EXECUTE FUNCTION trigger_match_check();
