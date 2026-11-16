-- TMDB's person id on each credit, so one person's jobs are joined into one
-- card by id, not by name (different people can share a name).
ALTER TABLE title_people ADD COLUMN IF NOT EXISTS tmdb_person_id INTEGER;
