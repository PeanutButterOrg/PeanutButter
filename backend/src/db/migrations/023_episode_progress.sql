-- Per-episode watch progress (Continue / Complete) for series & anime.
CREATE TABLE IF NOT EXISTS episode_progress (
    token_id    UUID NOT NULL REFERENCES device_tokens(id) ON DELETE CASCADE,
    episode_id  UUID NOT NULL REFERENCES episodes(id) ON DELETE CASCADE,
    title_id    UUID NOT NULL REFERENCES titles(id) ON DELETE CASCADE,
    position_ms BIGINT NOT NULL DEFAULT 0,
    duration_ms BIGINT,
    watched     BOOLEAN NOT NULL DEFAULT FALSE,
    updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (token_id, episode_id)
);

CREATE INDEX IF NOT EXISTS episode_progress_token_title_idx
    ON episode_progress (token_id, title_id);

CREATE INDEX IF NOT EXISTS episode_progress_token_updated_idx
    ON episode_progress (token_id, updated_at DESC);
