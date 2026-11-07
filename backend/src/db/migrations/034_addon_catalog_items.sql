-- Top titles of each enabled Stremio catalog add-on list ("Netflix" movies,
-- …), by IMDb id. The home Trending row mixes a few in and tags them with
-- the list's service.
CREATE TABLE IF NOT EXISTS addon_catalog_items (
    addon_id TEXT NOT NULL,
    catalog_id TEXT NOT NULL,
    media TEXT NOT NULL,
    service TEXT NOT NULL,
    imdb_id TEXT NOT NULL,
    rank INTEGER NOT NULL,
    synced_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (addon_id, catalog_id, media, imdb_id)
);
CREATE INDEX IF NOT EXISTS addon_catalog_items_imdb_idx ON addon_catalog_items (imdb_id);
