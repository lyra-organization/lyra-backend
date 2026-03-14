-- ============================================================
-- FIX: matches table constraints
-- ============================================================

-- Prevent duplicate match pairs
ALTER TABLE matches ADD CONSTRAINT uq_match_pair UNIQUE (user_a, user_b);

-- Prevent self-matches
ALTER TABLE matches ADD CONSTRAINT ck_no_self_match CHECK (user_a != user_b);

-- Add 'confirmed' status (both users accepted)
ALTER TABLE matches DROP CONSTRAINT matches_status_check;
ALTER TABLE matches ADD CONSTRAINT matches_status_check
  CHECK (status IN ('pending', 'approved', 'confirmed', 'rejected', 'met'));

-- Cascade on user deletion
ALTER TABLE matches DROP CONSTRAINT matches_user_a_fkey;
ALTER TABLE matches DROP CONSTRAINT matches_user_b_fkey;
ALTER TABLE matches
  ADD CONSTRAINT matches_user_a_fkey FOREIGN KEY (user_a) REFERENCES users(id) ON DELETE CASCADE,
  ADD CONSTRAINT matches_user_b_fkey FOREIGN KEY (user_b) REFERENCES users(id) ON DELETE CASCADE;

-- ============================================================
-- FIX: interactions table constraints + RLS
-- ============================================================

-- Cascade on user deletion
ALTER TABLE interactions DROP CONSTRAINT interactions_actor_id_fkey;
ALTER TABLE interactions DROP CONSTRAINT interactions_target_id_fkey;
ALTER TABLE interactions
  ADD CONSTRAINT interactions_actor_id_fkey FOREIGN KEY (actor_id) REFERENCES users(id) ON DELETE CASCADE,
  ADD CONSTRAINT interactions_target_id_fkey FOREIGN KEY (target_id) REFERENCES users(id) ON DELETE CASCADE;

-- Prevent self-interactions
ALTER TABLE interactions ADD CONSTRAINT ck_no_self_interaction CHECK (actor_id != target_id);

-- Enable RLS (was missing)
ALTER TABLE interactions ENABLE ROW LEVEL SECURITY;

-- Users can read their own interactions (writes go through Edge Function)
CREATE POLICY "Users can view own interactions" ON interactions
  FOR SELECT USING (
    auth.uid() IN (SELECT auth_id FROM users WHERE id IN (actor_id, target_id))
  );

-- ============================================================
-- FIX: Matching trigger
-- - ON CONFLICT targets the new unique constraint
-- - ORDER BY uses full weighted score (not just v_values)
-- - Cooldown checks BOTH users for pending/approved matches
-- - search_path pinned for SECURITY DEFINER safety
-- ============================================================
CREATE OR REPLACE FUNCTION trigger_match_check()
RETURNS TRIGGER LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_catalog
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
  WHERE u.id != NEW.user_id
    AND u.is_active = true
    AND ST_DWithin(l.location, NEW.location, 100)
    AND p.v_values IS NOT NULL

    -- Gender matching
    AND me.gender && u.show_me
    AND u.gender && me.show_me

    -- No prior interaction from me to them
    AND NOT EXISTS (SELECT 1 FROM interactions i WHERE i.actor_id = me.id AND i.target_id = u.id)

    -- Neither user has an active match (pending or approved = still in progress)
    AND NOT EXISTS (SELECT 1 FROM matches m WHERE (m.user_a = me.id OR m.user_b = me.id) AND m.status IN ('pending', 'approved', 'confirmed'))
    AND NOT EXISTS (SELECT 1 FROM matches m WHERE (m.user_a = u.id  OR m.user_b = u.id)  AND m.status IN ('pending', 'approved', 'confirmed'))

  ORDER BY total_score DESC
  LIMIT 1
  ON CONFLICT ON CONSTRAINT uq_match_pair DO NOTHING;

  RETURN NEW;
END;
$$;
