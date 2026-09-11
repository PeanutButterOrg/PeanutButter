-- Popcorn Time–style catalog fields:
--   released_at      → "Last added" sorts by theatrical / first-air date
--   tmdb_popularity  → "Trending" sorts by buzz (TMDB popularity ≈ Trakt watching)
ALTER TABLE titles
    ADD COLUMN IF NOT EXISTS released_at DATE;

ALTER TABLE ratings
    ADD COLUMN IF NOT EXISTS tmdb_popularity DOUBLE PRECISION;

CREATE INDEX IF NOT EXISTS titles_released_at_idx
    ON titles (released_at DESC NULLS LAST);

CREATE INDEX IF NOT EXISTS ratings_tmdb_popularity_idx
    ON ratings (tmdb_popularity DESC NULLS LAST);

-- Best-effort backfill when only year is known.
UPDATE titles
SET released_at = make_date(year, 1, 1)
WHERE released_at IS NULL
  AND year IS NOT NULL
  AND year BETWEEN 1888 AND 2100;
