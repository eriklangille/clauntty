-- Postgres: upsert a review and read its notes back
INSERT INTO reviews (id, pane, notes, created_at)
VALUES ($1, $2, $3::jsonb, now())
ON CONFLICT (id) DO UPDATE
SET notes = EXCLUDED.notes,
    updated_at = now()
RETURNING id;

SELECT r.id,
       r.notes ->> 'title' AS title,
       jsonb_array_length(r.notes -> 'files') AS files,
       count(*) FILTER (WHERE c.side = 'old') AS removed_comments
FROM reviews r
LEFT JOIN comments c ON c.review_id = r.id
WHERE r.created_at > now() - interval '24 hours'
  AND r.notes @> '{"base": "HEAD"}'
GROUP BY r.id
ORDER BY r.created_at DESC
LIMIT 20;
