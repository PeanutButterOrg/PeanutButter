-- The "Now in HD" row is gone (0.3.24): drop the tables its background check
-- used. HD-only sources are a rule in source ranking and don't need them.
-- 037 and 038 stay registered because servers on 0.3.23 already ran them.
DROP TABLE IF EXISTS title_quality_attempts;
DROP TABLE IF EXISTS title_quality;
