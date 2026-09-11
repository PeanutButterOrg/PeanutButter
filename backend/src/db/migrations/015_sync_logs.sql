-- Operator-visible sync event log (admin Sync tab).
CREATE TABLE IF NOT EXISTS sync_logs (
    id BIGSERIAL PRIMARY KEY,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    level TEXT NOT NULL DEFAULT 'info',
    phase TEXT,
    message TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS sync_logs_created_at_idx ON sync_logs (created_at DESC);
