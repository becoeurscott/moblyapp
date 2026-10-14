-- Every click must also be an impression: an annonce can't be opened without
-- having been on screen. Clicks recorded before impressions existed — and
-- opens since then from old app builds, links or notifications — have none.
--
-- Per listing and viewer, the first N clicks are covered by that viewer's N
-- existing impressions; each click beyond that gets an impression dated like
-- the click itself, so 30-day windows and daily charts stay aligned.
-- Anonymous clicks can't be matched and each get their own.
WITH clicks AS (
  SELECT ve.*,
         row_number() OVER (
           PARTITION BY ve."listingId", COALESCE(ve."userId", 'anon:' || ve."id")
           ORDER BY ve."createdAt"
         ) AS rn
  FROM "ViewEvent" ve
),
covered AS (
  SELECT "listingId", "userId", count(*) AS n
  FROM "ImpressionEvent"
  WHERE "userId" IS NOT NULL
  GROUP BY 1, 2
)
INSERT INTO "ImpressionEvent" ("id", "listingId", "userId", "source", "createdAt")
SELECT 'bf_' || c."id", c."listingId", c."userId", c."source", c."createdAt"
FROM clicks c
LEFT JOIN covered cv
  ON cv."listingId" = c."listingId" AND cv."userId" = c."userId"
WHERE c.rn > COALESCE(cv.n, 0)
ON CONFLICT ("id") DO NOTHING;
