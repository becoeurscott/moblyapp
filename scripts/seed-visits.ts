/**
 * Seed a handful of visit requests against the test owner's listings so the
 * owner inbox has data to render.
 *
 *   npx tsx scripts/seed-visits.ts
 *
 * Idempotent: wipes any prior seeded visits (tagged in `note`) first.
 */
import { prisma } from '../src/lib/prisma';

const OWNER_EMAIL = 'proprio.test@mobly.cm';
const TAG = '[seed]';

async function main() {
  const owner = await prisma.user.findUnique({ where: { email: OWNER_EMAIL } });
  if (!owner) throw new Error(`Owner ${OWNER_EMAIL} not found — run make-test-owner.ts first.`);

  const listings = await prisma.listing.findMany({
    where: { ownerId: owner.id },
    take: 3,
  });
  if (listings.length === 0) throw new Error('Owner has no listings.');

  // Clean any prior seeded visits.
  await prisma.visitRequest.deleteMany({
    where: { ownerId: owner.id, note: { contains: TAG } },
  });

  // Ensure we have a handful of "visitor" users. Reuse anyone that isn't the owner.
  const visitors = await prisma.user.findMany({
    where: { id: { not: owner.id } },
    take: 4,
  });
  if (visitors.length < 3) {
    // Create synthetic visitors on the fly.
    for (let i = visitors.length; i < 3; i++) {
      const v = await prisma.user.create({
        data: {
          phone: `+237 6${String(90000000 + i).slice(1)}`,
          fullName: ['Aïcha Mballa', 'Jean-Paul Ndong', 'Fatou Diarra'][i],
          isOwner: false,
          verified: i !== 2,
          city: 'Douala',
        },
      });
      visitors.push(v);
    }
  }

  const now = Date.now();
  const rows = [
    {
      listingId: listings[0].id,
      visitorId: visitors[0].id,
      scheduledAt: new Date(now + 1000 * 60 * 60 * 24), // +1 day
      status: 'REQUESTED' as const,
      note: `${TAG} Bonjour, je souhaite visiter demain après-midi si possible.`,
    },
    {
      listingId: listings[0].id,
      visitorId: visitors[1].id,
      scheduledAt: new Date(now + 1000 * 60 * 60 * 3), // +3h
      status: 'REQUESTED' as const,
      note: `${TAG} Disponible ce soir ?`,
    },
    {
      listingId: listings[Math.min(1, listings.length - 1)].id,
      visitorId: visitors[2].id,
      scheduledAt: new Date(now + 1000 * 60 * 60 * 48), // +2 days
      status: 'CONFIRMED' as const,
      note: `${TAG} Merci pour la confirmation, à samedi.`,
    },
    {
      listingId: listings[Math.min(2, listings.length - 1)].id,
      visitorId: visitors[0].id,
      scheduledAt: new Date(now - 1000 * 60 * 60 * 24 * 3), // -3 days
      status: 'COMPLETED' as const,
      note: `${TAG} Visite effectuée.`,
    },
  ];

  const FR_DAYS = ['dimanche','lundi','mardi','mercredi','jeudi','vendredi','samedi'];
  const FR_MONTHS = ['janv.','févr.','mars','avr.','mai','juin','juil.','août','sept.','oct.','nov.','déc.'];
  const fmt = (d: Date) =>
    `${FR_DAYS[d.getDay()]} ${d.getDate()} ${FR_MONTHS[d.getMonth()]} · ${String(d.getHours()).padStart(2,'0')}h${String(d.getMinutes()).padStart(2,'0')}`;
  const labels: Record<string, (d: Date) => string> = {
    REQUESTED: (d) => `Visite demandée · ${fmt(d)}`,
    CONFIRMED: (d) => `Visite confirmée · ${fmt(d)}`,
    CANCELLED: (d) => `Visite annulée · ${fmt(d)}`,
    COMPLETED: (d) => `Visite terminée · ${fmt(d)}`,
  };

  for (const r of rows) {
    const visit = await prisma.visitRequest.create({
      data: { ...r, ownerId: owner.id },
    });

    // Re-use / create the visitor↔owner thread and post a SYSTEM message
    // mirroring what the live route would have done.
    const existing = await prisma.thread.findFirst({
      where: {
        listingId: visit.listingId,
        AND: [
          { participants: { some: { userId: visit.visitorId } } },
          { participants: { some: { userId: owner.id } } },
        ],
      },
      select: { id: true },
    });
    const threadId = existing
      ? existing.id
      : (await prisma.thread.create({
          data: {
            listingId: visit.listingId,
            participants: { create: [{ userId: visit.visitorId }, { userId: owner.id }] },
          },
          select: { id: true },
        })).id;

    await prisma.message.create({
      data: {
        threadId,
        senderId: r.status === 'REQUESTED' ? visit.visitorId : owner.id,
        kind: 'SYSTEM',
        text: (labels[r.status] ?? labels.REQUESTED)(visit.scheduledAt),
        visitId: visit.id,
        visitAction: r.status,
      },
    });
    await prisma.thread.update({
      where: { id: threadId }, data: { updatedAt: new Date() },
    });
  }

  console.log(`  ✓ Seeded ${rows.length} visit requests + chat system messages for ${owner.fullName}`);
  await prisma.$disconnect();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
