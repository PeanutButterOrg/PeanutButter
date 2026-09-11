-- Server-owned content languages for TMDB ingest + Jackett filtering.
-- Empty preferred_languages = all languages.
ALTER TABLE app_settings
    ADD COLUMN IF NOT EXISTS preferred_languages TEXT NOT NULL DEFAULT 'en';

ALTER TABLE titles
    ADD COLUMN IF NOT EXISTS original_language TEXT;

CREATE INDEX IF NOT EXISTS titles_original_language_idx
    ON titles (original_language)
    WHERE original_language IS NOT NULL;
