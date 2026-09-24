-- Persist the full magnet URI + episode identity so Resume can restart the
-- same torrent without reopening the stream picker (avoids pack corruption).
ALTER TABLE stream_progress
    ADD COLUMN IF NOT EXISTS magnet TEXT NOT NULL DEFAULT '',
    ADD COLUMN IF NOT EXISTS season INT,
    ADD COLUMN IF NOT EXISTS episode INT,
    ADD COLUMN IF NOT EXISTS file_index INT;

CREATE INDEX IF NOT EXISTS idx_stream_progress_title_ep
    ON stream_progress (title_id, season, episode, updated_at DESC);
