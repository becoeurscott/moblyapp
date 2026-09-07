import { prisma } from '../lib/prisma';
import {
  appConfigSchema,
  DEFAULT_CONFIG,
  toPublicConfig,
  type AppConfigDoc,
  type FlagKey,
} from '../config/appConfigSchema';

/**
 * Access to the remotely-controlled configuration.
 *
 * Read on nearly every request, so it is cached in memory exactly like the
 * maintenance window: a Supabase round-trip is ~1.3 s and would tax every call
 * in the app. The TTL is short so a change made on one instance reaches the
 * others quickly, and the writing instance busts its own cache immediately.
 *
 * Two accessors, deliberately:
 *
 * - `getConfig()` is async and authoritative — use it in request handlers.
 * - `configSnapshot()` is synchronous and returns the last value read. Rate
 *   limiters, zod schema builders and the socket hub need a value *now*, in
 *   places where awaiting is not possible. Before the first successful load it
 *   returns the defaults, which is the safe direction (permissive).
 *
 * Never throws. A database fault yields the defaults — the app keeps working
 * as it shipped rather than losing every feature at once.
 */

const TTL_MS = 10_000;

let cached: { at: number; doc: AppConfigDoc; version: number } | null = null;
/** Last value successfully read, kept indefinitely for the sync accessor. */
let snapshot: AppConfigDoc = DEFAULT_CONFIG;
let snapshotVersion = 0;

export function bustConfigCache() {
  cached = null;
}

/** Parse a stored document, falling back to defaults on any malformed field. */
function parse(data: unknown): AppConfigDoc {
  const result = appConfigSchema.safeParse(data ?? {});
  if (result.success) return result.data;
  // A document that no longer matches the schema (a field removed in a deploy,
  // a hand-edited row) must not take the API down. Log loudly, serve defaults.
  console.error('[config] stored document failed validation, using defaults:', result.error.issues);
  return DEFAULT_CONFIG;
}

export async function getConfig(): Promise<AppConfigDoc> {
  if (cached && Date.now() - cached.at < TTL_MS) return cached.doc;
  try {
    const row = await prisma.appConfig.findUnique({ where: { id: 'singleton' } });
    const doc = parse(row?.data);
    const version = row?.version ?? 0;
    cached = { at: Date.now(), doc, version };
    snapshot = doc;
    snapshotVersion = version;
    return doc;
  } catch (err) {
    console.error('[config] read failed, using defaults:', err);
    return snapshot;
  }
}

/** Last known configuration. Never awaits, never throws. */
export function configSnapshot(): AppConfigDoc {
  return snapshot;
}

export async function getConfigVersion(): Promise<number> {
  await getConfig();
  return snapshotVersion;
}

export function configVersionSnapshot(): number {
  return snapshotVersion;
}

/** Warm the snapshot at boot so the first requests do not run on defaults. */
export async function primeConfig(): Promise<void> {
  await getConfig().catch(() => undefined);
}

// ─────────────────────────────────────────────────────────────
// Writes
// ─────────────────────────────────────────────────────────────

type Plain = Record<string, unknown>;

const isPlainObject = (v: unknown): v is Plain =>
  typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * Recursive merge used for partial updates.
 *
 * Objects merge key by key so the dashboard can send just the one flag it
 * changed; arrays replace wholesale, because a "merged" array (categories,
 * boost plans, an IP allowlist) has no sensible meaning — removing an entry
 * has to be expressible.
 */
export function deepMerge<T>(base: T, patch: unknown): T {
  if (!isPlainObject(patch)) return (patch === undefined ? base : (patch as T));
  const out: Plain = isPlainObject(base) ? { ...(base as unknown as Plain) } : {};
  for (const [key, value] of Object.entries(patch)) {
    if (value === undefined) continue;
    out[key] = isPlainObject(value) ? deepMerge(out[key], value) : value;
  }
  return out as unknown as T;
}

export interface ConfigWriteResult {
  doc: AppConfigDoc;
  version: number;
  /** The document as it was before the write, for the audit diff. */
  before: AppConfigDoc;
}

/**
 * Apply a partial patch. Validates the *merged* result, so a patch can never
 * leave the stored document in a shape the app cannot parse.
 */
export async function setConfig(patch: unknown, updatedBy: string | null): Promise<ConfigWriteResult> {
  const row = await prisma.appConfig.findUnique({ where: { id: 'singleton' } }).catch(() => null);
  const before = parse(row?.data);
  const merged = appConfigSchema.parse(deepMerge(before, patch));
  const version = (row?.version ?? 0) + 1;

  const saved = await prisma.appConfig.upsert({
    where: { id: 'singleton' },
    create: { id: 'singleton', data: merged as unknown as object, version, updatedBy },
    update: { data: merged as unknown as object, version, updatedBy },
  });

  cached = { at: Date.now(), doc: merged, version: saved.version };
  snapshot = merged;
  snapshotVersion = saved.version;
  return { doc: merged, version: saved.version, before };
}

/** Restore one section to the shipped defaults. */
export async function resetSection(
  section: keyof AppConfigDoc,
  updatedBy: string | null
): Promise<ConfigWriteResult> {
  return setConfig({ [section]: DEFAULT_CONFIG[section] }, updatedBy);
}

// ─────────────────────────────────────────────────────────────
// Reads used by the gates
// ─────────────────────────────────────────────────────────────

/** Is a feature on? Unknown keys are treated as on — never fail closed. */
export function isFlagEnabled(key: FlagKey, doc: AppConfigDoc = snapshot): boolean {
  return doc.flags[key]?.enabled ?? true;
}

/** The French sentence to show when a feature is off. */
export function flagMessage(key: FlagKey, doc: AppConfigDoc = snapshot): string {
  return doc.flags[key]?.message || doc.copy.featureDisabledMessage;
}

export { toPublicConfig };
