-- ============================================================
-- BRIDGE MIGRATION: Pre-requisites for fix_schema.sql
-- ============================================================

-- 1. UPGRADE USERS TABLE
-- Convert gender and show_me from TEXT to TEXT[] (Enables array matching)
ALTER TABLE users 
  ALTER COLUMN gender TYPE TEXT[] USING ARRAY[gender],
  ALTER COLUMN show_me TYPE TEXT[] USING ARRAY[show_me];

-- 2. UPGRADE PROFILES TABLE
-- Rename 'embedding' to 'v_values' and add the 7 new dimensions
ALTER TABLE profiles RENAME COLUMN embedding TO v_values;

ALTER TABLE profiles 
  ADD COLUMN v_big_five VECTOR(512),
  ADD COLUMN v_interests VECTOR(512),
  ADD COLUMN v_energy VECTOR(512),
  ADD COLUMN v_communication VECTOR(512),
  ADD COLUMN v_relationship VECTOR(512),
  ADD COLUMN v_compatibility VECTOR(512),
  ADD COLUMN v_keywords VECTOR(512);

-- 3. CLEAN UP OLD INDEX
DROP INDEX IF EXISTS idx_profiles_embedding;
CREATE INDEX idx_profiles_v_values ON profiles USING hnsw(v_values vector_cosine_ops);
CREATE INDEX idx_profiles_v_big_five ON profiles USING hnsw(v_big_five vector_cosine_ops);
