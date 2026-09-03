-- PeanutButter initial schema
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE titles (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    kind            TEXT NOT NULL CHECK (kind IN ('movie', 'series', 'anime')),
    title           TEXT NOT NULL,
    original_title  TEXT,
    synopsis        TEXT,
    description     TEXT,
    year            INTEGER,
    runtime_minutes INTEGER,
    poster_path     TEXT,
    backdrop_path   TEXT,
    tmdb_id         INTEGER,
    imdb_id         TEXT,
    anilist_id      INTEGER,
    mal_id          INTEGER,
    metadata        JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_synced_at  TIMESTAMPTZ
);

CREATE UNIQUE INDEX titles_tmdb_id_uidx ON titles (tmdb_id) WHERE tmdb_id IS NOT NULL;
CREATE UNIQUE INDEX titles_imdb_id_uidx ON titles (imdb_id) WHERE imdb_id IS NOT NULL;
CREATE UNIQUE INDEX titles_anilist_id_uidx ON titles (anilist_id) WHERE anilist_id IS NOT NULL;
CREATE UNIQUE INDEX titles_mal_id_uidx ON titles (mal_id) WHERE mal_id IS NOT NULL;
CREATE INDEX titles_kind_idx ON titles (kind);
CREATE INDEX titles_year_idx ON titles (year);
CREATE INDEX titles_title_idx ON titles (lower(title));
CREATE INDEX titles_updated_at_idx ON titles (updated_at);
CREATE INDEX titles_created_at_idx ON titles (created_at DESC);
CREATE INDEX titles_metadata_gin ON titles USING gin (metadata);

CREATE TABLE genres (
    id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE title_genres (
    title_id UUID NOT NULL REFERENCES titles (id) ON DELETE CASCADE,
    genre_id UUID NOT NULL REFERENCES genres (id) ON DELETE CASCADE,
    PRIMARY KEY (title_id, genre_id)
);

CREATE INDEX title_genres_genre_id_idx ON title_genres (genre_id);

CREATE TABLE seasons (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title_id       UUID NOT NULL REFERENCES titles (id) ON DELETE CASCADE,
    season_number  INTEGER NOT NULL,
    name           TEXT,
    overview       TEXT,
    poster_path    TEXT,
    air_date       DATE,
    episode_count  INTEGER,
    tmdb_season_id INTEGER,
    UNIQUE (title_id, season_number)
);

CREATE INDEX seasons_title_id_idx ON seasons (title_id);

CREATE TABLE episodes (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    season_id        UUID NOT NULL REFERENCES seasons (id) ON DELETE CASCADE,
    episode_number   INTEGER NOT NULL,
    name             TEXT,
    overview         TEXT,
    still_path       TEXT,
    air_date         DATE,
    runtime          INTEGER,
    tmdb_episode_id  INTEGER,
    UNIQUE (season_id, episode_number)
);

CREATE INDEX episodes_season_id_idx ON episodes (season_id);

CREATE TABLE file_references (
    id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title_id         UUID NOT NULL REFERENCES titles (id) ON DELETE CASCADE,
    season_id        UUID REFERENCES seasons (id) ON DELETE SET NULL,
    episode_id       UUID REFERENCES episodes (id) ON DELETE SET NULL,
    kind             TEXT NOT NULL DEFAULT 'local' CHECK (kind IN ('local', 'remote')),
    quality          TEXT,
    container        TEXT,
    codec            TEXT,
    size_bytes       BIGINT,
    file_path        TEXT NOT NULL,
    http_url         TEXT,
    content_hash     TEXT,
    available_peers  INTEGER NOT NULL DEFAULT 0,
    last_check       TIMESTAMPTZ,
    created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (file_path)
);

CREATE INDEX file_references_title_id_idx ON file_references (title_id);
CREATE INDEX file_references_episode_id_idx ON file_references (episode_id);

CREATE TABLE ratings (
    id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title_id           UUID NOT NULL UNIQUE REFERENCES titles (id) ON DELETE CASCADE,
    tmdb_vote_average  DOUBLE PRECISION,
    tmdb_vote_count    INTEGER,
    imdb_rating        DOUBLE PRECISION,
    imdb_votes         INTEGER,
    anilist_score      DOUBLE PRECISION,
    anilist_popularity INTEGER,
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX ratings_tmdb_vote_average_idx ON ratings (tmdb_vote_average DESC NULLS LAST);
CREATE INDEX ratings_anilist_popularity_idx ON ratings (anilist_popularity DESC NULLS LAST);

CREATE TABLE trailers (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    title_id    UUID NOT NULL REFERENCES titles (id) ON DELETE CASCADE,
    name        TEXT NOT NULL,
    youtube_key TEXT NOT NULL,
    site        TEXT NOT NULL DEFAULT 'YouTube',
    size        INTEGER,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (title_id, youtube_key)
);

CREATE INDEX trailers_title_id_idx ON trailers (title_id);

CREATE TABLE sync_state (
    id           INTEGER PRIMARY KEY CHECK (id = 1),
    last_sync_at TIMESTAMPTZ,
    syncing      BOOLEAN NOT NULL DEFAULT FALSE,
    total_titles INTEGER NOT NULL DEFAULT 0,
    last_error   TEXT
);

INSERT INTO sync_state (id, syncing, total_titles)
VALUES (1, FALSE, 0)
ON CONFLICT (id) DO NOTHING;

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER titles_set_updated_at
    BEFORE UPDATE ON titles
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
