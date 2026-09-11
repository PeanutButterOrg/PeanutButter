-- TMDB movie and TV IDs share one integer space; uniqueness must include kind.
DROP INDEX IF EXISTS titles_tmdb_id_uidx;
CREATE UNIQUE INDEX IF NOT EXISTS titles_tmdb_id_kind_uidx
    ON titles (tmdb_id, kind)
    WHERE tmdb_id IS NOT NULL;
