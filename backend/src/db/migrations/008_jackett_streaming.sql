ALTER TABLE app_settings
    ADD COLUMN IF NOT EXISTS jackett_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS jackett_url TEXT,
    ADD COLUMN IF NOT EXISTS jackett_api_key TEXT,
    ADD COLUMN IF NOT EXISTS streaming_resolution TEXT NOT NULL DEFAULT '1080p';

CREATE TABLE IF NOT EXISTS stream_progress (
    magnet_key TEXT PRIMARY KEY,
    title_id UUID,
    title TEXT NOT NULL DEFAULT '',
    resume_position BIGINT NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
