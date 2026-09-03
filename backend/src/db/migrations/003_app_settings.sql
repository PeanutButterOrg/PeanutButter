CREATE TABLE IF NOT EXISTS app_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    tmdb_api_key TEXT NOT NULL DEFAULT '',
    omdb_api_key TEXT NOT NULL DEFAULT '',
    anilist_client_id TEXT,
    media_path TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO app_settings (id) VALUES (1)
ON CONFLICT (id) DO NOTHING;
