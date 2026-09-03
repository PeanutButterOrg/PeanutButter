CREATE TABLE IF NOT EXISTS subtitles (
    id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    file_id    UUID NOT NULL REFERENCES file_references (id) ON DELETE CASCADE,
    language   TEXT NOT NULL,
    label      TEXT NOT NULL,
    format     TEXT NOT NULL DEFAULT 'srt',
    content    TEXT NOT NULL,
    source     TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (file_id, language)
);

CREATE INDEX IF NOT EXISTS subtitles_file_id_idx ON subtitles (file_id);
