-- 6-digit codes become short-lived *pairing* codes. Apps trade a code for a
-- long random key (POST /pair) and only the key's SHA-256 is stored.
--
-- Codes that existed before this migration keep working as a bearer token
-- for 30 days so already-paired devices keep running until their app
-- updates (updated apps exchange the stored code for a key automatically).

ALTER TABLE device_tokens
    ADD COLUMN IF NOT EXISTS is_admin BOOLEAN NOT NULL DEFAULT false,
    ADD COLUMN IF NOT EXISTS code_expires_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS legacy_bearer_until TIMESTAMPTZ;

UPDATE device_tokens
SET code_expires_at = now() + interval '30 days',
    legacy_bearer_until = now() + interval '30 days'
WHERE code_expires_at IS NULL;

-- The row mirroring app_settings.app_token was the admin (it could change
-- server settings); keep that role on the row itself.
UPDATE device_tokens d
SET is_admin = true
FROM app_settings s
WHERE s.id = 1 AND s.app_token IS NOT NULL AND d.token = s.app_token;

CREATE TABLE IF NOT EXISTS device_keys (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    device_id    UUID NOT NULL REFERENCES device_tokens (id) ON DELETE CASCADE,
    key_hash     TEXT NOT NULL UNIQUE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ
);

CREATE INDEX IF NOT EXISTS device_keys_device_idx ON device_keys (device_id);
