-- "Notify me" on a series: per paired device record, like watch progress.
CREATE TABLE IF NOT EXISTS title_follows (
    token_id   UUID NOT NULL REFERENCES device_tokens (id) ON DELETE CASCADE,
    title_id   UUID NOT NULL REFERENCES titles (id) ON DELETE CASCADE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (token_id, title_id)
);

-- Episodes of followed series that aired after the follow; apps fetch the
-- undelivered ones, show a notification and mark them delivered.
CREATE TABLE IF NOT EXISTS episode_alerts (
    token_id     UUID NOT NULL REFERENCES device_tokens (id) ON DELETE CASCADE,
    episode_id   UUID NOT NULL REFERENCES episodes (id) ON DELETE CASCADE,
    title_id     UUID NOT NULL REFERENCES titles (id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    delivered_at TIMESTAMPTZ,
    PRIMARY KEY (token_id, episode_id)
);

CREATE INDEX IF NOT EXISTS episode_alerts_pending_idx
    ON episode_alerts (token_id) WHERE delivered_at IS NULL;
