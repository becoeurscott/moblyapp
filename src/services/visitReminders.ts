import { prisma } from '../lib/prisma';
import { notifyUser } from './push';
import { isFlagEnabled } from './config';

const EVERY_MS = 5 * 60 * 1000;
const HOUR = 60 * 60 * 1000;
const TZ = 'Africa/Douala';

/** "15h00" in Douala time. */
function hourLabel(d: Date): string {
  const parts = new Intl.DateTimeFormat('fr-FR', {
    timeZone: TZ, hour: '2-digit', minute: '2-digit', hour12: false,
  }).formatToParts(d);
  const h = parts.find((p) => p.type === 'hour')?.value ?? '00';
  const m = parts.find((p) => p.type === 'minute')?.value ?? '00';
  return `${h}h${m}`;
}

const include = {
  listing: { select: { title: true } },
  visitor: { select: { fullName: true } },
} as const;

/** Douala is UTC+1 all year (no DST). */
const DOUALA_OFFSET = HOUR;
const LATE_OK = 15 * 60 * 1000;

type Slot = 'reminderEveSentAt' | 'reminderMorningSentAt' | 'reminder1hSentAt' | 'reminder30mSentAt';
const SLOTS: Slot[] = ['reminderEveSentAt', 'reminderMorningSentAt', 'reminder1hSentAt', 'reminder30mSentAt'];

/** UTC instant of local midnight (Douala) of the visit day. */
function localMidnight(at: Date): number {
  const local = at.getTime() + DOUALA_OFFSET;
  return local - (local % (24 * HOUR)) - DOUALA_OFFSET;
}

/** When a slot fires, or null when it does not apply to this visit. */
export function slotFireAt(slot: Slot, at: Date): number | null {
  const midnight = localMidnight(at);
  switch (slot) {
    case 'reminderEveSentAt': return midnight - 6 * HOUR; // 18h00 the day before
    case 'reminderMorningSentAt':
      return at.getTime() - midnight < 9 * HOUR ? null : midnight + 8 * HOUR; // 08h00
    case 'reminder1hSentAt': return at.getTime() - HOUR;
    case 'reminder30mSentAt': return at.getTime() - 30 * 60 * 1000;
  }
}

function slotBody(slot: Slot, title: string, at: Date): string {
  const h = hourLabel(at);
  switch (slot) {
    case 'reminderEveSentAt': return `Rappel : votre visite de ${title} est demain à ${h}`;
    case 'reminderMorningSentAt': return `Aujourd'hui à ${h} : visite de ${title}`;
    case 'reminder1hSentAt': return `Votre visite de ${title} est dans 1 heure (${h})`;
    case 'reminder30mSentAt': return `Votre visite de ${title} est dans 30 minutes (${h})`;
  }
}

async function confirmedReminders(now: Date): Promise<number> {
  let sent = 0;
  const t = now.getTime();
  const visits = await prisma.visitRequest.findMany({
    where: {
      status: 'CONFIRMED',
      scheduledAt: { gt: now, lte: new Date(t + 32 * HOUR) },
      OR: SLOTS.map((f) => ({ [f]: null })),
    },
    include,
    take: 500,
  });
  for (const v of visits) {
    // Latest due slot only: an earlier one that is still within its lateness
    // window is superseded by a closer reminder.
    const due = SLOTS.filter((f) => {
      if (v[f] !== null) return false;
      const fire = slotFireAt(f, v.scheduledAt);
      return fire !== null && fire <= t && t < fire + LATE_OK;
    });
    const slot = due[due.length - 1];
    if (!slot) continue;
    // Claim first: only the run that flips the field sends.
    const claimed = await prisma.visitRequest.updateMany({
      where: { id: v.id, status: 'CONFIRMED', [slot]: null, scheduledAt: v.scheduledAt },
      data: { [slot]: now },
    });
    if (claimed.count === 0) continue;
    const body = slotBody(slot, v.listing.title, v.scheduledAt);
    for (const userId of [v.visitorId, v.ownerId]) {
      await notifyUser({
        userId,
        type: 'visit.reminder',
        title: 'Rappel de visite',
        body,
        payload: { visitId: v.id, listingId: v.listingId },
      }).catch((err) => console.error('[visit-reminders] notify failed', err));
    }
    sent++;
  }
  return sent;
}

async function pendingReminders(now: Date): Promise<number> {
  let sent = 0;
  const due = await prisma.visitRequest.findMany({
    where: {
      status: 'REQUESTED',
      pendingReminderSentAt: null,
      createdAt: { lte: new Date(now.getTime() - 12 * HOUR) },
      scheduledAt: { gt: now },
    },
    include,
    take: 200,
  });
  for (const v of due) {
    const claimed = await prisma.visitRequest.updateMany({
      where: { id: v.id, status: 'REQUESTED', pendingReminderSentAt: null },
      data: { pendingReminderSentAt: now },
    });
    if (claimed.count === 0) continue;
    const name = v.visitor.fullName?.trim() || 'Un visiteur';
    await notifyUser({
      userId: v.ownerId,
      type: 'visit.requested',
      title: 'Demande de visite en attente',
      body: `${name} attend votre réponse pour ${v.listing.title}`,
      payload: { visitId: v.id, listingId: v.listingId },
    }).catch((err) => console.error('[visit-reminders] notify failed', err));
    sent++;
  }
  return sent;
}

/** One pass. Exported for scripts and tests. */
export async function runVisitReminders(now = new Date()): Promise<number> {
  return (await confirmedReminders(now)) + (await pendingReminders(now));
}

let running = false;

/**
 * Every 5 minutes, in process (same pattern as boost expiry). Gated by the
 * `visits.serverReminders` flag so the app's local reminders and the server's
 * pushes never both fire. The claim in updateMany keeps several instances safe.
 */
export function startVisitReminders() {
  const run = async () => {
    if (running || !isFlagEnabled('visits.serverReminders')) return;
    running = true;
    try {
      await runVisitReminders();
    } catch (err) {
      console.error('[visit-reminders] run failed:', err);
    } finally {
      running = false;
    }
  };
  setTimeout(run, 30_000).unref();
  setInterval(run, EVERY_MS).unref();
}
