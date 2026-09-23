-- Per title/episode Jackett result cache for the stream picker (3-day TTL in app logic).
CREATE TABLE IF NOT EXISTS stream_search_cache (
    cache_key TEXT PRIMARY KEY,
    title_id UUID REFERENCES titles (id) ON DELETE CASCADE,
    season INTEGER,
    episode INTEGER,
    sources JSONB NOT NULL DEFAULT '[]'::jsonb,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS stream_search_cache_title_id_idx
    ON stream_search_cache (title_id);

CREATE INDEX IF NOT EXISTS stream_search_cache_updated_at_idx
    ON stream_search_cache (updated_at);
