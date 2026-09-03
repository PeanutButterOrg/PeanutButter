-- Per-device API tokens with token-scoped play history and favorites.
-- Catalog / Jackett listings stay shared across all tokens.

CREATE TABLE IF NOT EXISTS device_tokens (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name       TEXT NOT NULL,
    token      TEXT NOT NULL UNIQUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS device_tokens_created_at_idx ON device_tokens (created_at DESC);

-- Attach existing progress to a default token (seeded in ensure_device_tokens).
ALTER TABLE user_progress
    ADD COLUMN IF NOT EXISTS token_id UUID REFERENCES device_tokens (id) ON DELETE CASCADE;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE table_name = 'user_progress' AND constraint_name = 'user_progress_pkey'
    ) THEN
        ALTER TABLE user_progress DROP CONSTRAINT user_progress_pkey;
    END IF;
END $$;

-- token_id may still be null until ensure_device_tokens backfills; PK added there if needed.
CREATE INDEX IF NOT EXISTS user_progress_token_updated_at_idx
    ON user_progress (token_id, updated_at DESC);
