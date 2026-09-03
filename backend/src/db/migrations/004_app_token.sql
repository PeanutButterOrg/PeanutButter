ALTER TABLE app_settings
    ADD COLUMN IF NOT EXISTS app_token TEXT;
