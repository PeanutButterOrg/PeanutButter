-- Torrent bookmarks (magnet + fileIndex) are per paired device.
-- Revoking a device_tokens row CASCADE-deletes that client's resume cache.
ALTER TABLE stream_progress
    ADD COLUMN IF NOT EXISTS token_id UUID REFERENCES device_tokens (id) ON DELETE CASCADE;

UPDATE stream_progress sp
SET token_id = (SELECT id FROM device_tokens ORDER BY created_at ASC LIMIT 1)
WHERE token_id IS NULL
  AND EXISTS (SELECT 1 FROM device_tokens);

DELETE FROM stream_progress WHERE token_id IS NULL;

ALTER TABLE stream_progress
    ALTER COLUMN token_id SET NOT NULL;

ALTER TABLE stream_progress DROP CONSTRAINT IF EXISTS stream_progress_pkey;
ALTER TABLE stream_progress ADD PRIMARY KEY (token_id, magnet_key);

DROP INDEX IF EXISTS idx_stream_progress_title_ep;
CREATE INDEX IF NOT EXISTS idx_stream_progress_token_title_ep
    ON stream_progress (token_id, title_id, season, episode, updated_at DESC);
