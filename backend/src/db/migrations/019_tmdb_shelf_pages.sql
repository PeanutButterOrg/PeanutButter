-- Track which TMDB list pages are already cached per shelf / media type.
-- Initial sync fills pages 1..5; scrolling catalog fetches deeper pages on demand.
CREATE TABLE IF NOT EXISTS tmdb_shelf_pages (
    shelf TEXT NOT NULL,
    media TEXT NOT NULL,
    page INTEGER NOT NULL CHECK (page >= 1),
    total_pages INTEGER NOT NULL DEFAULT 1 CHECK (total_pages >= 1),
    item_count INTEGER NOT NULL DEFAULT 0,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shelf, media, page)
);

CREATE INDEX IF NOT EXISTS tmdb_shelf_pages_depth_idx
    ON tmdb_shelf_pages (shelf, media, page DESC);
