/**
 * Tiny in-memory TTL cache for read-heavy GET responses.
 *
 * The listing search hits Supabase over the network, which costs ~1.3s of
 * fixed round-trip latency regardless of payload size (a no-DB endpoint on the
 * same server answers in 1ms). Browse traffic repeats the same handful of
 * queries, so caching the serialized response turns every repeat hit into a
 * memory read. Writes bust the whole namespace — listing data is small and
 * mutations are rare, so precise invalidation isn't worth the bug surface.
 */

type Entry = { value: unknown; expiresAt: number };

const store = new Map<string, Entry>();

/** Drop expired entries. Cheap — the map only ever holds a few dozen keys. */
function sweep(now: number) {
  for (const [k, e] of store) if (e.expiresAt <= now) store.delete(k);
}

export function cacheGet<T>(key: string): T | undefined {
  const e = store.get(key);
  if (!e) return undefined;
  if (e.expiresAt <= Date.now()) {
    store.delete(key);
    return undefined;
  }
  return e.value as T;
}

export function cacheSet(key: string, value: unknown, ttlMs: number) {
  const now = Date.now();
  if (store.size > 200) sweep(now);
  store.set(key, { value, expiresAt: now + ttlMs });
}

/** Invalidate every key beginning with `prefix` (call after any write). */
export function cacheBust(prefix: string) {
  for (const k of store.keys()) if (k.startsWith(prefix)) store.delete(k);
}
