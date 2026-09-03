ALTER TABLE titles
    ADD COLUMN IF NOT EXISTS jackett_checked_at TIMESTAMPTZ;

CREATE TABLE IF NOT EXISTS jackett_listings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title_id UUID NOT NULL REFERENCES titles (id) ON DELETE CASCADE,
    magnet TEXT NOT NULL,
    torrent_title TEXT NOT NULL DEFAULT '',
    seeders INTEGER NOT NULL DEFAULT 0,
    peers INTEGER NOT NULL DEFAULT 0,
    rating INTEGER NOT NULL DEFAULT 1,
    health TEXT NOT NULL DEFAULT 'dead',
    size TEXT NOT NULL DEFAULT '',
    tracker TEXT NOT NULL DEFAULT '',
    indexer TEXT NOT NULL DEFAULT '',
    language TEXT NOT NULL DEFAULT '',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (title_id, magnet)
);

CREATE INDEX IF NOT EXISTS jackett_listings_title_id_idx ON jackett_listings (title_id);
CREATE INDEX IF NOT EXISTS jackett_listings_seeders_idx ON jackett_listings (seeders DESC);

CREATE TABLE IF NOT EXISTS jackett_sync_state (
    id INTEGER PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    syncing BOOLEAN NOT NULL DEFAULT FALSE,
    last_full_sync_at TIMESTAMPTZ,
    last_update_at TIMESTAMPTZ,
    titles_done INTEGER NOT NULL DEFAULT 0,
    titles_total INTEGER NOT NULL DEFAULT 0,
    last_error TEXT
);

INSERT INTO jackett_sync_state (id)
VALUES (1)
ON CONFLICT (id) DO NOTHING;
