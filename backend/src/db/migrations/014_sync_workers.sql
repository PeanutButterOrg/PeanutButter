-- Added after 013 was already applied without this column on some installs.
ALTER TABLE sync_state
    ADD COLUMN IF NOT EXISTS workers_active INTEGER NOT NULL DEFAULT 0;
