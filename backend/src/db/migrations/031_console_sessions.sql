-- Signed-in console browsers (SHA-256 of the cookie token), so a restart or
-- a server self-update doesn't sign everyone out.
CREATE TABLE IF NOT EXISTS console_sessions (
    token_hash TEXT PRIMARY KEY,
    expires_at TIMESTAMPTZ NOT NULL
);
CREATE INDEX IF NOT EXISTS console_sessions_expires_idx ON console_sessions (expires_at);
