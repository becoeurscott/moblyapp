import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler } from '../lib/http';
import { requireAuth } from '../middleware/auth';

// Static reference data used by the app's pickers.
const REGIONS = [
  { name: 'Littoral', cities: ['Douala', 'Nkongsamba', 'Édéa', 'Loum', 'Manjo', 'Mbanga'] },
  { name: 'Centre', cities: ['Yaoundé', 'Mbalmayo', 'Obala', 'Bafia', 'Nanga-Eboko', 'Akonolinga'] },
  { name: 'Ouest', cities: ['Bafoussam', 'Dschang', 'Foumban', 'Mbouda', 'Bandjoun', 'Bafang'] },
  { name: 'Sud-Ouest', cities: ['Buéa', 'Limbé', 'Kumba', 'Tiko', 'Mamfe', 'Mutengene'] },
  { name: 'Nord-Ouest', cities: ['Bamenda', 'Kumbo', 'Ndop', 'Wum', 'Fundong', 'Bali'] },
  { name: 'Sud', cities: ['Ebolowa', 'Kribi', 'Sangmélima', 'Ambam', 'Djoum'] },
  { name: 'Est', cities: ['Bertoua', 'Batouri', 'Abong-Mbang', 'Yokadouma', 'Bélabo'] },
  { name: 'Adamaoua', cities: ['Ngaoundéré', 'Meiganga', 'Tibati', 'Banyo', 'Tignère'] },
  { name: 'Nord', cities: ['Garoua', 'Guider', 'Figuil', 'Poli', 'Lagdo'] },
  { name: 'Extrême-Nord', cities: ['Maroua', 'Kousséri', 'Mokolo', 'Yagoua', 'Kaélé'] },
];

const QUARTIERS: Record<string, string[]> = {
  Douala: ['Akwa', 'Bonapriso', 'Bonanjo', 'Bali', 'Deido', 'Bonamoussadi', 'Makepe', 'Bonabéri', 'New Bell', 'Ndokotti', 'Logbessou', 'Kotto'],
  Yaoundé: ['Bastos', 'Nlongkak', 'Essos', 'Nsam', 'Mvog-Mbi', 'Nsimeyong', 'Biyem-Assi', 'Mendong', 'Odza', 'Ekounou'],
  Bafoussam: ['Tamdja', 'Kamkop', 'Djeleng', 'Tougang', 'Banengo', 'Famla'],
  Kribi: ['Dombé', 'Mpangou', 'Talla', 'Afan-Mabé', 'Bwambé'],
  Limbé: ['Down Beach', 'Bota', 'Mile 4', 'Church Street', 'New Town'],
  Buéa: ['Molyko', 'Great Soppo', 'Bonduma', 'Bomaka', 'Mile 16', 'Muea'],
};

const CATEGORIES = ['Chambres', 'Studios', 'Appartements', 'Villas', 'Bureaux', 'Boutiques', 'Coworking', 'Commercial'];

export const miscRouter = Router();

/** GET /api/geo — regions → cities → quartiers for the location picker. */
miscRouter.get('/geo', (_req, res) => {
  res.json({ regions: REGIONS, quartiers: QUARTIERS });
});

/** GET /api/categories */
miscRouter.get('/categories', (_req, res) => {
  res.json({ categories: CATEGORIES });
});

// Notifications
export const notificationsRouter = Router();

notificationsRouter.get(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const items = await prisma.notification.findMany({
      where: { userId: req.userId! },
      orderBy: { createdAt: 'desc' },
    });
    res.json({ items, unread: items.filter((n) => !n.read).length });
  })
);

notificationsRouter.post(
  '/read-all',
  requireAuth,
  asyncHandler(async (req, res) => {
    await prisma.notification.updateMany({ where: { userId: req.userId! }, data: { read: true } });
    res.json({ ok: true });
  })
);

// Reviews (nested under listings in the router index)
export const reviewsRouter = Router({ mergeParams: true });

reviewsRouter.get(
  '/:id/reviews',
  asyncHandler(async (req, res) => {
    const items = await prisma.review.findMany({
      where: { listingId: req.params.id },
      include: { user: { select: { id: true, fullName: true, avatarUrl: true } } },
      orderBy: { createdAt: 'desc' },
    });
    res.json({ items });
  })
);

reviewsRouter.post(
  '/:id/reviews',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { rating, text } = z
      .object({ rating: z.number().int().min(1).max(5), text: z.string().optional() })
      .parse(req.body);
    const review = await prisma.review.create({
      data: { listingId: req.params.id, userId: req.userId!, rating, text },
    });
    // Recompute listing rating.
    const agg = await prisma.review.aggregate({
      where: { listingId: req.params.id },
      _avg: { rating: true },
      _count: true,
    });
    await prisma.listing.update({
      where: { id: req.params.id },
      data: { rating: agg._avg.rating ?? null, reviewCount: agg._count },
    });
    res.status(201).json({ review });
  })
);

// Public profile of any user — used by the chat header on iOS so tapping the
// other party opens their profile (name, "Membre depuis", listings, verified
// badge). Deliberately excludes phone, email, and everything else that could
// leak private data across users.
export const usersRouter = Router();

usersRouter.get(
  '/:id',
  asyncHandler(async (req, res) => {
    const u = await prisma.user.findUnique({
      where: { id: req.params.id },
      select: {
        id: true,
        fullName: true,
        avatarUrl: true,
        avatarColor: true,
        verified: true,
        isOwner: true,
        city: true,
        region: true,
        createdAt: true,
      },
    });
    if (!u) {
      res.status(404).json({ error: 'Utilisateur introuvable', code: 'NOT_FOUND' });
      return;
    }
    // Attach how many listings this user has published (owner view) and the
    // average rating of their listings so the profile card can show it at a
    // glance, in one round trip.
    const listingsCount = await prisma.listing.count({ where: { ownerId: u.id } });
    const agg = await prisma.listing.aggregate({
      where: { ownerId: u.id },
      _avg: { rating: true },
      _sum: { reviewCount: true },
    });
    res.json({
      user: {
        ...u,
        listingsCount,
        avgRating: agg._avg.rating ?? null,
        totalReviews: agg._sum.reviewCount ?? 0,
      },
    });
  })
);
