import type { Listing, User } from '@prisma/client';

const dealLabel: Record<string, string> = {
  RENT: 'À louer',
  BUY: 'Acheter',
  SHORT: 'Court séjour',
};

export function formatFcfa(n: number): string {
  // Group thousands with a plain space, e.g. 80000 -> "80 000".
  return `${String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ' ')} FCFA`;
}

/** Shape a Listing for the client. Includes both raw + display fields. */
export function serializeListing(
  l: Listing & { owner?: Pick<User, 'id' | 'fullName' | 'verified' | 'rating' | 'avatarUrl'> | null }
) {
  const deals: string[] = [dealLabel[l.deal] ?? 'À louer'];
  if (l.furnished) deals.push('Meublé');
  else deals.push('Non meublé');

  return {
    id: l.id,
    title: l.title,
    category: l.category,
    deal: l.deal,
    deals,
    region: l.region,
    city: l.city,
    neighborhood: l.neighborhood,
    location: [l.neighborhood, l.city].filter(Boolean).join(', '),
    priceFcfa: l.priceFcfa,
    price: formatFcfa(l.priceFcfa),
    furnished: l.furnished,
    rooms: l.rooms,
    subtitle: l.furnished ? `Meublé · ${l.rooms} ch` : `${l.rooms} ch`,
    about: l.about ?? '',
    rating: l.rating,
    reviewCount: l.reviewCount,
    verified: l.verified,
    tags: l.tags,
    coverUrl: l.coverUrl,
    imageName: l.imageName,
    photos: l.photos,
    available: l.available,
    status: l.status,
    boosted: l.status === 'BOOSTED',
    views: l.views,
    contacts: l.contacts,
    favorites: l.favorites,
    boostDaysLeft: l.boostDaysLeft,
    boostExpiresAt: l.boostExpiresAt,
    lat: l.lat,
    lng: l.lng,
    owner: l.owner
      ? {
          id: l.owner.id,
          fullName: l.owner.fullName,
          verified: l.owner.verified,
          rating: l.owner.rating,
          avatarUrl: l.owner.avatarUrl,
        }
      : undefined,
    createdAt: l.createdAt,
  };
}

export function serializeUser(u: User) {
  return {
    id: u.id,
    phone: u.phone,
    fullName: u.fullName,
    email: u.email,
    isOwner: u.isOwner,
    verified: u.verified,
    city: u.city,
    region: u.region,
    rating: u.rating,
    avatarUrl: u.avatarUrl,
    avatarColor: u.avatarColor,
    isAdmin: u.isAdmin,
    createdAt: u.createdAt,
  };
}
