-- TMDB's own order for its lists (trending, popular), so those sorts show what
-- TMDB shows. The stored popularity score was only refreshed while a title was on
-- a list, so titles that trended weeks ago stayed on top.
CREATE TABLE IF NOT EXISTS tmdb_shelf_items (
    shelf TEXT NOT NULL,
    media TEXT NOT NULL,
    tmdb_id INTEGER NOT NULL,
    rank INTEGER NOT NULL,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (shelf, media, tmdb_id)
);

-- Refetch the lists once so the ranks fill in right after this update.
DELETE FROM tmdb_shelf_pages;
