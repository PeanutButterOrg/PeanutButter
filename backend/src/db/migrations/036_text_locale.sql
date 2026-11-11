-- Language a title's text (title, overview, episodes, genres) was fetched in.
-- Existing rows are NULL: the boot job re-fetches them in English once.
-- New rows are fetched in English already.
ALTER TABLE titles ADD COLUMN IF NOT EXISTS text_locale TEXT;
ALTER TABLE titles ALTER COLUMN text_locale SET DEFAULT 'en-US';
