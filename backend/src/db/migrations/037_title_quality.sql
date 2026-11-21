-- Which movies have an HD copy yet, for "Now in HD" (see src/quality.rs).
CREATE TABLE IF NOT EXISTS title_quality (
    title_id        UUID PRIMARY KEY REFERENCES titles (id) ON DELETE CASCADE,
    -- 'ready' (a playable 720p+ copy) | 'none'
    status          TEXT NOT NULL,
    best_resolution INTEGER,
    good_sources    INTEGER NOT NULL DEFAULT 0,
    checked_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    -- When it became ready; NULL while it isn't.
    good_since      TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS title_quality_ready_idx ON title_quality (good_since DESC) WHERE status = 'ready';
