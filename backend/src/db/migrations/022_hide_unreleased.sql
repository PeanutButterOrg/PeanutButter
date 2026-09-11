-- Drop titles that are not released yet (future theatrical / first-air dates).
DELETE FROM titles
WHERE released_at > CURRENT_DATE
   OR year > EXTRACT(YEAR FROM CURRENT_DATE)::int;
