/**
 * Wipe test / seed data that accumulated during the visit-flow build.
 *
 *   npx tsx scripts/cleanup-test-data.ts             # dry-run: report counts
 *   npx tsx scripts/cleanup-test-data.ts --apply     # actually delete
 *
 * What it removes:
 *   • VisitRequest rows whose note is tagged `[seed]`
 *   • SYSTEM messages that were linked to those visits (visitId in the deleted set)
 *   • Empty Threads left behind (no messages, no lastMessage)
 *   • AppSession / AppEvent for the test owner + visitor accounts, so the
 *     analytics view starts from a clean baseline
 *
 * What it keeps:
 *   • Real user accounts, listings, favorites, real conversations
 *   • Real (non-tagged) visit requests
 *
 * Idempotent — safe to re-run.
 */
import { prisma } from '../src/lib/prisma';

const APPLY = process.argv.includes('--apply');

const TEST_EMAILS = ['proprio.test@mobly.cm', 'visiteur.test@mobly.cm'];

async function main() {
  console.log(APPLY ? '\n  ⚠  APPLYING DELETIONS\n' : '\n  ℹ  DRY-RUN (pass --apply to delete)\n');

  // 1. Test users (owner + visitor accounts we created for the visit flow).
  const testUsers = await prisma.user.findMany({
    where: { email: { in: TEST_EMAILS } },
    select: { id: true, email: true },
  });
  const testUserIds = testUsers.map((u) => u.id);

  // 2. Seeded visits — [seed]-tagged notes OR any visit between two test users.
  const seededVisits = await prisma.visitRequest.findMany({
    where: {
      OR: [
        { note: { contains: '[seed]' } },
        { AND: [{ visitorId: { in: testUserIds } }, { ownerId: { in: testUserIds } }] },
      ],
    },
    select: { id: true },
  });
  const seededIds = seededVisits.map((v) => v.id);
  console.log(`  test VisitRequests      : ${seededIds.length}`);

  // 3. System messages linked to those visits.
  const linkedMessages = await prisma.message.count({
    where: { visitId: { in: seededIds } },
  });
  console.log(`  linked SYSTEM messages  : ${linkedMessages}`);
  const testDeviceIds = (
    await prisma.appSession.findMany({
      where: { userId: { in: testUserIds } },
      select: { deviceId: true },
      distinct: ['deviceId'],
    })
  ).map((s) => s.deviceId);
  const testSessions = await prisma.appSession.count({
    where: {
      OR: [
        { userId: { in: testUserIds } },
        { deviceId: { in: testDeviceIds } },
      ],
    },
  });
  const testEvents = await prisma.appEvent.count({
    where: {
      OR: [
        { userId: { in: testUserIds } },
        { session: { deviceId: { in: testDeviceIds } } },
      ],
    },
  });
  console.log(`  test AppSession rows    : ${testSessions}`);
  console.log(`  test AppEvent rows      : ${testEvents}`);

  if (!APPLY) {
    console.log('\n  Re-run with --apply to delete.\n');
    await prisma.$disconnect();
    return;
  }

  // Delete order: events → sessions → messages → visits → empty threads.
  const delEvents = await prisma.appEvent.deleteMany({
    where: {
      OR: [
        { userId: { in: testUserIds } },
        { session: { deviceId: { in: testDeviceIds } } },
      ],
    },
  });
  const delSessions = await prisma.appSession.deleteMany({
    where: {
      OR: [
        { userId: { in: testUserIds } },
        { deviceId: { in: testDeviceIds } },
      ],
    },
  });
  const delMessages = await prisma.message.deleteMany({
    where: { visitId: { in: seededIds } },
  });
  const delVisits = await prisma.visitRequest.deleteMany({
    where: { id: { in: seededIds } },
  });

  // Empty threads — no messages remain.
  const emptyThreads = await prisma.thread.findMany({
    where: { messages: { none: {} } },
    select: { id: true },
  });
  const delThreadParts = await prisma.threadParticipant.deleteMany({
    where: { threadId: { in: emptyThreads.map((t) => t.id) } },
  });
  const delThreads = await prisma.thread.deleteMany({
    where: { id: { in: emptyThreads.map((t) => t.id) } },
  });

  console.log(`\n  ✓ deleted AppEvent           : ${delEvents.count}`);
  console.log(`  ✓ deleted AppSession         : ${delSessions.count}`);
  console.log(`  ✓ deleted Message            : ${delMessages.count}`);
  console.log(`  ✓ deleted VisitRequest       : ${delVisits.count}`);
  console.log(`  ✓ deleted ThreadParticipant  : ${delThreadParts.count}`);
  console.log(`  ✓ deleted empty Thread       : ${delThreads.count}\n`);

  await prisma.$disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
