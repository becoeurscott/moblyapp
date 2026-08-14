import { PrismaClient, DealType, ListingStatus } from '@prisma/client';

const prisma = new PrismaClient();

async function main() {
  console.log('Seeding…');

  const owner = await prisma.user.upsert({
    where: { phone: '+237677123456' },
    update: {},
    create: {
      phone: '+237677123456',
      fullName: 'Awa Mballa',
      email: 'awa@example.cm',
      isOwner: true,
      verified: true,
      rating: 4.9,
    },
  });

  const visitor = await prisma.user.upsert({
    where: { phone: '+237690000000' },
    update: {},
    create: { phone: '+237690000000', fullName: 'Jeanne Ndongo', isOwner: false, verified: true },
  });

  const listings: Array<{
    title: string;
    category: string;
    deal: DealType;
    region: string;
    city: string;
    neighborhood: string;
    priceFcfa: number;
    furnished: boolean;
    rooms: number;
    imageName: string;
    tags: string[];
    status: ListingStatus;
    views: number;
    contacts: number;
    favorites: number;
    boostDaysLeft?: number;
    about: string;
  }> = [
    {
      title: 'Studio meublé · Akwa', category: 'Studios', deal: DealType.RENT, region: 'Littoral',
      city: 'Douala', neighborhood: 'Akwa', priceFcfa: 80000, furnished: true, rooms: 1,
      imageName: 'ListingGreen', tags: ['Meublé', 'Wifi', 'Parking'], status: ListingStatus.BOOSTED,
      views: 1204, contacts: 86, favorites: 31, boostDaysLeft: 22,
      about: 'Studio lumineux et calme à 5 min du marché d’Akwa, entièrement meublé, eau et électricité stables.',
    },
    {
      title: 'Bureau · Bonanjo', category: 'Bureaux', deal: DealType.RENT, region: 'Littoral',
      city: 'Douala', neighborhood: 'Bonanjo', priceFcfa: 150000, furnished: false, rooms: 0,
      imageName: 'ListingYellow', tags: ['Wifi', 'Climatisation', 'Sécurité 24/7'], status: ListingStatus.ACTIVE,
      views: 742, contacts: 28, favorites: 10,
      about: 'Open space de 40 m² au cœur du quartier administratif, idéal pour une petite équipe.',
    },
    {
      title: 'Appartement · Bonapriso', category: 'Appartements', deal: DealType.RENT, region: 'Littoral',
      city: 'Douala', neighborhood: 'Bonapriso', priceFcfa: 220000, furnished: true, rooms: 2,
      imageName: 'ListingPink', tags: ['Meublé', 'Parking'], status: ListingStatus.PENDING,
      views: 0, contacts: 0, favorites: 0,
      about: 'Bel appartement 2 chambres meublé, quartier résidentiel calme et sécurisé.',
    },
    {
      title: 'Villa · Bastos', category: 'Villas', deal: DealType.BUY, region: 'Centre',
      city: 'Yaoundé', neighborhood: 'Bastos', priceFcfa: 350000, furnished: true, rooms: 4,
      imageName: 'ListingLoft', tags: ['Piscine', 'Parking', 'Sécurité 24/7'], status: ListingStatus.ACTIVE,
      views: 512, contacts: 41, favorites: 22,
      about: 'Villa haut standing 4 chambres avec piscine, dans le quartier des ambassades.',
    },
  ];

  // Clear existing demo listings for idempotency.
  await prisma.listing.deleteMany({ where: { ownerId: owner.id } });

  for (const l of listings) {
    await prisma.listing.create({
      data: {
        ...l,
        ownerId: owner.id,
        rating: l.views > 0 ? 4.7 : null,
        reviewCount: l.favorites,
        boostExpiresAt: l.boostDaysLeft
          ? new Date(Date.now() + l.boostDaysLeft * 86400000)
          : null,
      },
    });
  }

  console.log(`Seeded ${listings.length} listings for owner ${owner.fullName} (visitor: ${visitor.fullName})`);
}

main()
  .catch((e) => {
    console.error(e);
    process.exit(1);
  })
  .finally(() => prisma.$disconnect());
