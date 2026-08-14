/**
 * Send a test notification to every Mobly user.
 *
 *   npx tsx scripts/broadcast.ts "Promo" "Boost à moitié prix ce weekend."
 *   npx tsx scripts/broadcast.ts "Titre" "Corps" ANNOUNCEMENT
 *
 * Inserts a `Notification` row per user + fans out an APNs push where a
 * device token is registered. Uses the same code path as the admin route
 * so a real production broadcast behaves identically.
 */
import { prisma } from '../src/lib/prisma';

async function main() {
  const title = process.argv[2] ?? 'Bienvenue sur Mobly';
  const body  = process.argv[3] ?? 'Bonne visite — trouvez votre prochain espace ✨';
  const type  = process.argv[4] ?? 'ANNOUNCEMENT';

  const users = await prisma.user.findMany({ select: { id: true } });

  await prisma.notification.createMany({
    data: users.map((u) => ({
      userId: u.id,
      type, title, body,
      payload: {},
    })),
  });

  const { pushToUser } = await import('../src/services/push');
  await Promise.all(
    users.map((u) =>
      pushToUser(u.id, { title, body }).catch(() => {})
    )
  );

  console.log(`\n  ✓ Broadcast sent to ${users.length} users`);
  console.log('    title:', title);
  console.log('    body :', body);
  console.log('    type :', type, '\n');
  await prisma.$disconnect();
}

main().catch((e) => { console.error(e); process.exit(1); });
