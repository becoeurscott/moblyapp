import { prisma } from '../lib/prisma';
import { cacheBust } from '../lib/cache';
import { emitToUsers } from '../realtime/hub';

const EVERY_MS = 10 * 60 * 1000;

/**
 * End boosts whose time is up. Nothing else ever did: a boosted annonce kept
 * its BOOSTED status (top of the feed, "Boostée" badge) forever. Runs in the
 * process every 10 minutes, so it does not depend on an external cron.
 */
export async function expireBoosts(): Promise<number> {
  const expired = await prisma.listing.findMany({
    where: { status: 'BOOSTED', boostExpiresAt: { lte: new Date() } },
    select: { id: true, ownerId: true },
  });
  if (expired.length === 0) return 0;
  await prisma.listing.updateMany({
    where: { id: { in: expired.map((l) => l.id) } },
    data: { status: 'ACTIVE', boostDaysLeft: null, boostExpiresAt: null },
  });
  cacheBust('listings:');
  emitToUsers([...new Set(expired.map((l) => l.ownerId))], { type: 'owner:stats' });
  return expired.length;
}

export function startBoostExpiry() {
  const run = () =>
    expireBoosts().catch((err) => console.error('[boost] expiry failed:', err));
  run();
  setInterval(run, EVERY_MS).unref();
}
