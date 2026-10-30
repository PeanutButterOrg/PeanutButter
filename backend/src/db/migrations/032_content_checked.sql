-- When a title last passed the explicit-content check (TMDB adult flag,
-- erotic / softcore keywords, NC-17 / XXX ratings). NULL = never checked:
-- the boot cleanup re-checks those against TMDB and removes explicit ones.
ALTER TABLE titles ADD COLUMN IF NOT EXISTS content_checked_at TIMESTAMPTZ;
