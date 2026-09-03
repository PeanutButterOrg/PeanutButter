ALTER TABLE app_settings
    ADD COLUMN IF NOT EXISTS opensubtitles_enabled BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS opensubtitles_api_key TEXT;

CREATE TABLE IF NOT EXISTS title_subtitles (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title_id        UUID NOT NULL REFERENCES titles (id) ON DELETE CASCADE,
    language        TEXT NOT NULL,
    label           TEXT NOT NULL,
    format          TEXT NOT NULL DEFAULT 'srt',
    content         TEXT NOT NULL,
    source          TEXT NOT NULL,
    season_number   INTEGER,
    episode_number  INTEGER,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS title_subtitles_uniq
    ON title_subtitles (
        title_id,
        language,
        COALESCE(season_number, 0),
        COALESCE(episode_number, 0)
    );

CREATE INDEX IF NOT EXISTS title_subtitles_title_id_idx ON title_subtitles (title_id);
