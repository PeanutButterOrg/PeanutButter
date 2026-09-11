-- Remove adult / Sex genre and titles tagged with blocked adult genres.
-- Also drop titles with explicit adult content ratings.

DELETE FROM titles
WHERE id IN (
    SELECT DISTINCT tg.title_id
    FROM title_genres tg
    JOIN genres g ON g.id = tg.genre_id
    WHERE lower(g.name) IN (
        'sex', 'adult', 'erotica', 'erotic', 'hentai', 'porn',
        'pornographic', 'pornography', 'xxx', 'softcore', 'hardcore',
        'adult animation', 'adults only', 'x'
    )
    OR lower(g.name) LIKE '%hentai%'
    OR lower(g.name) LIKE '%porn%'
);

DELETE FROM titles
WHERE upper(trim(COALESCE(content_rating, ''))) IN ('XXX', 'AO')
   OR upper(COALESCE(content_rating, '')) LIKE '%XXX%';

DELETE FROM genres
WHERE lower(name) IN (
    'sex', 'adult', 'erotica', 'erotic', 'hentai', 'porn',
    'pornographic', 'pornography', 'xxx', 'softcore', 'hardcore',
    'adult animation', 'adults only', 'x'
)
OR lower(name) LIKE '%hentai%'
OR lower(name) LIKE '%porn%';
