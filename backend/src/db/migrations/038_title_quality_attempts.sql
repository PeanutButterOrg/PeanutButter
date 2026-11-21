-- When the "Now in HD" check last tried a movie and no source answered (see
-- src/quality.rs). Kept apart from title_quality so a failed search never
-- touches the last good verdict, but still waits before it's retried.
CREATE TABLE IF NOT EXISTS title_quality_attempts (
    title_id     UUID PRIMARY KEY REFERENCES titles (id) ON DELETE CASCADE,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
