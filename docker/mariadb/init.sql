-- Database and user are created via environment variables.
-- This file intentionally left for any additional init steps.

-- Ensure charset and collation
ALTER DATABASE `suitecrm` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Add api_key column to users table
ALTER TABLE users ADD COLUMN api_key VARCHAR(64) DEFAULT NULL;
