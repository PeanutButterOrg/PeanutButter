ALTER TABLE ratings
    ADD COLUMN IF NOT EXISTS rt_score INTEGER;

CREATE INDEX IF NOT EXISTS ratings_rt_score_idx
    ON ratings (rt_score DESC NULLS LAST);
