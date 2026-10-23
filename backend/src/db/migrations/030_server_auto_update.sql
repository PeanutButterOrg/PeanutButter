-- Console "Auto-update" switch for server self-updates (off by default).
ALTER TABLE app_settings
    ADD COLUMN IF NOT EXISTS server_auto_update BOOLEAN NOT NULL DEFAULT FALSE;
