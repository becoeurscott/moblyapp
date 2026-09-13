/**
 * Simulate owner-trial states for testing the 7-day free trial + one-time
 * inscription fee. Backdates (or resets) a real account so the app shows the
 * trial countdown, the locked paywall, or an active paid owner — without
 * waiting 7 real days.
 *
 *   npx tsx scripts/set-owner-trial.ts <phone|userId> expire   # trial lapsed → dashboard locked, listings hidden
 *   npx tsx scripts/set-owner-trial.ts <phone|userId> ending   # 1 day left → countdown banner
 *   npx tsx scripts/set-owner-trial.ts <phone|userId> fresh    # restart a full 7-day trial
 *   npx tsx scripts/set-owner-trial.ts <phone|userId> paid     # inscription fee paid → active for good
 *
 * The payment itself is simulated in-app (no real PSP); this only moves the
 * server-side trial dates so the whole cycle is demoable end to end.
 */
import { prisma } from '../src/lib/prisma';

const DAY = 24 * 60 * 60 * 1000;
type Mode = 'expire' | 'ending' | 'fresh' | 'paid';

async function main() {
  const who = process.argv[2];
  const mode = (process.argv[3] ?? 'expire').toLowerCase() as Mode;
  if (!who || !['expire', 'ending', 'fresh', 'paid'].includes(mode)) {
    console.error('Usage: set-owner-trial.ts <phone|userId> <expire|ending|fresh|paid>');
    process.exit(1);
  }

  const user = await prisma.user.findFirst({
    where: { OR: [{ id: who }, { phone: who }] },
    select: { id: true, phone: true, fullName: true },
  });
  if (!user) {
    console.error(`No user matching "${who}"`);
    process.exit(1);
  }

  const data: {
    isOwner: boolean;
    ownerTrialStartedAt?: Date;
    ownerPaid?: boolean;
  } = { isOwner: true };

  switch (mode) {
    case 'expire': data.ownerTrialStartedAt = new Date(Date.now() - 8 * DAY); data.ownerPaid = false; break;
    case 'ending': data.ownerTrialStartedAt = new Date(Date.now() - 6 * DAY); data.ownerPaid = false; break;
    case 'fresh':  data.ownerTrialStartedAt = new Date();                     data.ownerPaid = false; break;
    case 'paid':   data.ownerPaid = true; break;
  }

  await prisma.user.update({ where: { id: user.id }, data });
  console.log(`✓ ${user.fullName} (${user.phone}) → ${mode}`, data);
}

main()
  .then(() => process.exit(0))
  .catch((e) => { console.error(e); process.exit(1); });
