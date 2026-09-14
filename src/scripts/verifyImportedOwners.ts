/**
 * Backfill: mark every owner of an Airbnb-imported listing as verified.
 *
 * Imported listings carry the tag "airbnb-import" and are seeded ACTIVE, but
 * their host accounts were created before we treated imported hosts as fully
 * verified. This promotes those owners to identity-verified (and phone-verified)
 * so their annonces show the "Propriétaire vérifié" badge and behave like any
 * verified owner. The importer now does this on its own; this one-off catches
 * the rows imported before that change.
 *
 * Run once against the deployed DB:
 *   node dist/scripts/verifyImportedOwners.js
 *
 * Idempotent: re-running only touches owners still missing the badge.
 */
import { prisma } from '../lib/prisma';

async function main() {
  // Distinct owner ids across every airbnb-import listing.
  const listings = await prisma.listing.findMany({
    where: { tags: { has: 'airbnb-import' } },
    select: { ownerId: true },
    distinct: ['ownerId'],
  });
  const ownerIds = listings.map((l) => l.ownerId);
  if (ownerIds.length === 0) {
    console.log('No airbnb-import listings found — nothing to do.');
    return;
  }

  const res = await prisma.user.updateMany({
    where: { id: { in: ownerIds }, identityVerified: false },
    data: { verified: true, identityVerified: true, verifiedAt: new Date() },
  });
  console.log(
    `Imported owners: ${ownerIds.length} total, ${res.count} newly verified.`
  );
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
