-- Extra art + people like Jellyfin's TMDB provider, plus local resume/favorites.

ALTER TABLE titles ADD COLUMN IF NOT EXISTS logo_path TEXT;
ALTER TABLE titles ADD COLUMN IF NOT EXISTS thumb_path TEXT;

CREATE TABLE IF NOT EXISTS title_people (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title_id     UUID NOT NULL REFERENCES titles (id) ON DELETE CASCADE,
    name         TEXT NOT NULL,
    character    TEXT,
    job          TEXT,
    department   TEXT NOT NULL CHECK (department IN ('cast', 'crew')),
    profile_path TEXT,
    sort_order   INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS title_people_title_id_idx ON title_people (title_id);

CREATE TABLE IF NOT EXISTS user_progress (
    title_id    UUID PRIMARY KEY REFERENCES titles (id) ON DELETE CASCADE,
    episode_id  UUID REFERENCES episodes (id) ON DELETE SET NULL,
    file_id     UUID REFERENCES file_references (id) ON DELETE SET NULL,
    position_ms BIGINT NOT NULL DEFAULT 0,
    duration_ms BIGINT,
    watched     BOOLEAN NOT NULL DEFAULT FALSE,
    favorite    BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS user_progress_updated_at_idx ON user_progress (updated_at DESC);
