ALTER TABLE app_settings
    ADD COLUMN IF NOT EXISTS admin_password_hash TEXT;
