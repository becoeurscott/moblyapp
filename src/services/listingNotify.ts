import { prisma } from '../lib/prisma';
import { notifyUser, pushConfigured } from './push';

/**
 * "Nouvelle annonce à <ville>" push, sent the moment an annonce goes live —
 * on publish by a verified owner, or when an admin activates one. Notifies
 * users in the same city who have a device registered, never the owner.
 */
export async function notifyNewListing(
  listing: { id: string; title: string; city: string; neighborhood?: string | null; priceFcfa: number },
  ownerId: string,
) {
  if (!pushConfigured()) return;

  const price = new Intl.NumberFormat('fr-FR').format(listing.priceFcfa) + ' FCFA';
  const where = listing.neighborhood ? `${listing.neighborhood}, ${listing.city}` : listing.city;

  const users = await prisma.user.findMany({
    where: {
      id: { not: ownerId },
      city: listing.city,
      devices: { some: { pushToken: { not: null } } },
    },
    select: { id: true },
    take: 500,
  });

  for (const u of users) {
    await notifyUser({
      userId: u.id,
      type: 'new_listing',
      title: `Nouvelle annonce à ${where} 🏠`,
      body: `${listing.title} — ${price}. Découvrez-la maintenant !`,
      payload: { listingId: listing.id },
    }).catch(() => {});
  }
}
