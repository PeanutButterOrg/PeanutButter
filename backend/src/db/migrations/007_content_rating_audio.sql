-- Content rating (PG / TV-14) and audio codec for local files.

ALTER TABLE titles ADD COLUMN IF NOT EXISTS content_rating TEXT;
ALTER TABLE file_references ADD COLUMN IF NOT EXISTS audio_codec TEXT;
