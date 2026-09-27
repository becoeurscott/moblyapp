/** Bounded, process-local TTL cache. Writes invalidate pending loads too. */
type Entry = { value: unknown; expiresAt: number };
const MAX_ENTRIES = 200;
const store = new Map<string, Entry>();
const pending = new Map<string, Promise<unknown>>();

export function cacheGet<T>(key: string): T | undefined {
  const entry = store.get(key);
  if (!entry) return undefined;
  if (entry.expiresAt <= Date.now()) {
    store.delete(key);
    return undefined;
  }
  return entry.value as T;
}

export function cacheSet(key: string, value: unknown, ttlMs: number) {
  const now = Date.now();
  for (const [k, entry] of store) if (entry.expiresAt <= now) store.delete(k);
  store.delete(key);
  while (store.size >= MAX_ENTRIES) store.delete(store.keys().next().value!);
  store.set(key, { value, expiresAt: now + ttlMs });
}

/** Share concurrent misses; a write during a load prevents stale repopulation. */
export async function cacheRemember<T>(key: string, ttlMs: number, load: () => Promise<T>): Promise<T> {
  const hit = cacheGet<T>(key);
  if (hit !== undefined) return hit;
  const running = pending.get(key);
  if (running) return running as Promise<T>;
  const task = Promise.resolve().then(load);
  pending.set(key, task);
  try {
    const value = await task;
    if (pending.get(key) === task) cacheSet(key, value, ttlMs);
    return value;
  } finally {
    if (pending.get(key) === task) pending.delete(key);
  }
}

export function cacheBust(prefix: string) {
  for (const key of store.keys()) if (key.startsWith(prefix)) store.delete(key);
  for (const key of pending.keys()) if (key.startsWith(prefix)) pending.delete(key);
}
