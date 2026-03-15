-- ============================================================
-- BRIDGE MIGRATION: Pre-requisites for fix_schema.sql
-- Safe no-op on fresh installs; applies upgrades on older schemas.
-- ============================================================

-- 1. UPGRADE USERS TABLE
-- Convert gender and show_me from TEXT to TEXT[] only if still scalar TEXT
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'users'
      AND column_name = 'gender' AND data_type = 'text'
  ) THEN
    ALTER TABLE users
      ALTER COLUMN gender TYPE TEXT[] USING ARRAY[gender],
      ALTER COLUMN show_me TYPE TEXT[] USING ARRAY[show_me];
  END IF;
END $$;

-- 2. UPGRADE PROFILES TABLE
-- Rename 'embedding' to 'v_values' only if the old column still exists
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'profiles'
      AND column_name = 'embedding'
  ) THEN
    ALTER TABLE profiles RENAME COLUMN embedding TO v_values;
  END IF;
END $$;

-- Add the 7 new vector dimensions (IF NOT EXISTS = no-op on fresh installs)
ALTER TABLE profiles
  ADD COLUMN IF NOT EXISTS v_big_five VECTOR(512),
  ADD COLUMN IF NOT EXISTS v_interests VECTOR(512),
  ADD COLUMN IF NOT EXISTS v_energy VECTOR(512),
  ADD COLUMN IF NOT EXISTS v_communication VECTOR(512),
  ADD COLUMN IF NOT EXISTS v_relationship VECTOR(512),
  ADD COLUMN IF NOT EXISTS v_compatibility VECTOR(512),
  ADD COLUMN IF NOT EXISTS v_keywords VECTOR(512);

-- 3. CLEAN UP OLD INDEX AND CREATE NEW ONES
DROP INDEX IF EXISTS idx_profiles_embedding;
CREATE INDEX IF NOT EXISTS idx_profiles_v_values ON profiles USING hnsw(v_values vector_cosine_ops);
CREATE INDEX IF NOT EXISTS idx_profiles_v_big_five ON profiles USING hnsw(v_big_five vector_cosine_ops);
