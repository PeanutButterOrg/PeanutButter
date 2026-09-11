-- Catalog sync progress for the server console Sync tab.
ALTER TABLE sync_state
    ADD COLUMN IF NOT EXISTS phase TEXT,
    ADD COLUMN IF NOT EXISTS progress_done INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS progress_total INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN IF NOT EXISTS workers_active INTEGER NOT NULL DEFAULT 0;
