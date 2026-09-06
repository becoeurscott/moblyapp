import { prisma } from '../lib/prisma';

/**
 * The maintenance window is read on (almost) every request, so it is cached in
 * memory rather than fetched from Supabase each time — a DB round-trip here is
 * ~1.3 s and would tax every single call in the app (see the perf note in the
 * backend memo). The cache is short so a window flipped from the dashboard
 * takes effect across instances within a few seconds, and it is busted
 * immediately on the instance that made the change.
 */
const TTL_MS = 5_000;

export interface MaintenanceState {
  enabled: boolean;
  message: string | null;
  endsAt: Date | null;
  startedAt: Date | null;
  updatedAt: Date | null;
  updatedBy: string | null;
}

const OFF: MaintenanceState = {
  enabled: false,
  message: null,
  endsAt: null,
  startedAt: null,
  updatedAt: null,
  updatedBy: null,
};

let cached: { at: number; state: MaintenanceState } | null = null;

/** Drop the cache so the next read hits the database. */
export function bustMaintenanceCache() {
  cached = null;
}

/**
 * Current window. Never throws: if the settings row cannot be read (database
 * down, migration not yet applied) we report "not in maintenance" rather than
 * locking every user out of a working app because of an unrelated fault.
 */
export async function getMaintenance(): Promise<MaintenanceState> {
  if (cached && Date.now() - cached.at < TTL_MS) return cached.state;
  try {
    const row = await prisma.maintenanceWindow.findUnique({
      where: { id: 'singleton' },
    });
    const state: MaintenanceState = row
      ? {
          enabled: row.enabled,
          message: row.message,
          endsAt: row.endsAt,
          startedAt: row.startedAt,
          updatedAt: row.updatedAt,
          updatedBy: row.updatedBy,
        }
      : OFF;
    cached = { at: Date.now(), state };
    return state;
  } catch (err) {
    console.error('[maintenance] read failed, failing open:', err);
    return OFF;
  }
}

/** Upsert the singleton row and refresh the cache in one step. */
export async function setMaintenance(input: {
  enabled: boolean;
  message: string | null;
  endsAt: Date | null;
  updatedBy: string | null;
}): Promise<MaintenanceState> {
  const current = await prisma.maintenanceWindow
    .findUnique({ where: { id: 'singleton' } })
    .catch(() => null);

  // startedAt marks when THIS window opened — preserved while it stays on so
  // the dashboard can show how long the app has been down, and cleared when
  // it is lifted.
  const startedAt = input.enabled ? (current?.enabled ? current.startedAt : new Date()) : null;

  const data = {
    enabled: input.enabled,
    message: input.message,
    endsAt: input.endsAt,
    startedAt,
    updatedBy: input.updatedBy,
  };

  const row = await prisma.maintenanceWindow.upsert({
    where: { id: 'singleton' },
    create: { id: 'singleton', ...data },
    update: data,
  });

  bustMaintenanceCache();
  return {
    enabled: row.enabled,
    message: row.message,
    endsAt: row.endsAt,
    startedAt: row.startedAt,
    updatedAt: row.updatedAt,
    updatedBy: row.updatedBy,
  };
}

/** Wire shape shared by the public and admin endpoints. */
export function serializeMaintenance(s: MaintenanceState) {
  return {
    enabled: s.enabled,
    message: s.message,
    endsAt: s.endsAt ? s.endsAt.toISOString() : null,
    startedAt: s.startedAt ? s.startedAt.toISOString() : null,
    updatedAt: s.updatedAt ? s.updatedAt.toISOString() : null,
    updatedBy: s.updatedBy,
    /// Server clock, so the app can count down without trusting the device
    /// time — a phone with a wrong clock would otherwise show a nonsense timer.
    serverTime: new Date().toISOString(),
  };
}
