-- Fallback torrent sources (Stremio add-ons such as Torrentio): master switch,
-- reliability threshold and the installed add-ons, as one JSON document.
ALTER TABLE app_settings
    ADD COLUMN IF NOT EXISTS stream_providers JSONB;
