import { prisma } from '../src/lib/prisma';
async function main() {
  const sessions = await prisma.appSession.findMany({
    orderBy: { startedAt: 'desc' },
    take: 5,
    select: { id: true, userId: true, deviceId: true, startedAt: true, endedAt: true, os: true, appVersion: true },
  });
  console.log('\n--- last 5 sessions ---');
  for (const s of sessions) console.log(s);
  const events = await prisma.appEvent.findMany({
    orderBy: { createdAt: 'desc' },
    take: 15,
    select: { name: true, payload: true, userId: true, createdAt: true },
  });
  console.log('\n--- last 15 events ---');
  for (const e of events)
    console.log(e.createdAt.toISOString(), e.name, JSON.stringify(e.payload), 'user:', e.userId);
  await prisma.$disconnect();
}
main();
