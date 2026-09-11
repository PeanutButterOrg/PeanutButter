-- Tag titles by which TMDB shelves they came from so home rows match sync lists.
ALTER TABLE titles
    ADD COLUMN IF NOT EXISTS list_trending_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS list_popular_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS list_fresh_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS titles_list_trending_idx ON titles (list_trending_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS titles_list_popular_idx ON titles (list_popular_at DESC NULLS LAST);
CREATE INDEX IF NOT EXISTS titles_list_fresh_idx ON titles (list_fresh_at DESC NULLS LAST);
