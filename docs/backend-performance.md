# Backend performance review

Reviewed the supplied video transcript and local backend on 2026-09-24.
The transcript recommends measuring first, reducing database work, selecting
needed data, pagination, caching, and overlapping independent I/O. It also
suggests background jobs: critical writes in this app remain awaited because
fire-and-forget work can be lost on process termination.

## Changes

- Listing search filters shadow bans through the owner relation instead of
  downloading all banned user IDs before running the listing and count queries.
  Search, owner eligibility, pagination and response fields are preserved.
- Identical concurrent listing/restriction misses share one load. Cache entries
  are capped at 200. Invalidating during a load prevents that load from caching
  stale results, and subsequent callers start a fresh read.
- Configuration and maintenance each share one in-flight read, with generation
  checks so older reads cannot overwrite state after an admin update.
- Account and restriction checks run concurrently after token verification.
  The account itself is still fetched on each request, preserving suspension
  and token revocation checks. Cached restrictions are filtered on actual expiry.
- Message history gets a composite (threadId, createdAt) index, replacing the
  single-column threadId index. Its benefit still needs a database query plan
  and representative data to measure.
- Slow database operations (500 ms+) log model/action and duration, without
  query values. Requests taking 1 second+ log request ID, route, duration,
  database operation count and summed database operation duration. Set
  PERFORMANCE_LOG=true to log all request summaries during investigation.
  Database durations include network and pool waits; overlapping operations
  can sum to more than the request duration. ORM operation counts are not
  SQL statement counts. Timing begins after the process receives the request,
  so it cannot measure hosting startup delay.

## Verification

Run `npm run build`, `npx prisma validate`, and
`node --import tsx --test tests/performance.test.ts`.
Validation completed: the backend compiled against a clean install of the locked
dependencies, Prisma schema validation passed, and all 9 regression tests passed.
The clean install was used because some existing local dependency files timed out
while reading.

Tests mock database calls: they check burst coalescing, invalidation races,
failures/retries, capacity, expiration, config/maintenance refresh races and
account restrictions. The listing endpoint test also verifies that a burst of
10 requests uses one listing/count pair and retains the visibility filters.
They are not production latency measurements.

## Deployment and measurement still required

Deploy the backend and apply the included Prisma migration using the project's
normal deployment process. For a large Message table, schedule the regular
index creation during a low-traffic window because it blocks writes while
building. No production database was changed here.

The checked-in render.yaml now specifies `plan: 0.5c-512mb`, Render's 0.5 CPU /
512 MB paid web service plan. Render documents that free services sleep after
15 minutes without inbound traffic and take about a minute to resume:
https://render.com/docs/free. Deploying this blueprint after upgrading the
service removes that hosting cold start. Code caching alone cannot fix cold
starts if the live service is still running on the free plan.

Existing code comments claim roughly 1.3 seconds per Supabase round trip; this
is historical context, not a measurement from this review. Check that the API
and database are geographically close, and inspect pool wait time before
changing connection limits.

After deploying, compare warmed and first-after-idle latency separately. Measure
p50/p95 for listings, listing detail, threads and authenticated account reads
under representative concurrency. Compare database operation timings with total
request duration. Use EXPLAIN (ANALYZE, BUFFERS) on representative read queries in
a safe environment to verify the new index and owner-restriction filter.

Further work should follow measurements: the inbox currently returns all threads,
and browse defaults to 200 listings (up to 500). Reducing those limits requires
matching iOS pagination to avoid silently hiding results. Keep shared caches
limited to public data or keys scoped to the correct user; no HTTP caching of
private account responses was enabled.
