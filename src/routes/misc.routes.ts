import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth } from '../middleware/auth';
import { broadcastReview } from '../realtime/hub';
import { featureGate, restrictionGate, assertNotBlocked } from '../middleware/gates';
import { configSnapshot } from '../services/config';

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
  featureGate('reviews.post'),
  restrictionGate('REVIEW_POST'),
  asyncHandler(async (req, res) => {
    const limits = configSnapshot().limits;
    const { rating, text } = z
      .object({
        rating: z.number().int().min(1).max(5),
        text: z.string().max(limits.reviewMaxChars).optional(),
      })
      .parse(req.body);

    // A configurable floor on review length. Set above zero to stop one-word
    // "ok" reviews from being farmed to inflate a listing's rating.
    if (limits.reviewMinChars > 0 && (text ?? '').trim().length < limits.reviewMinChars) {
      throw new ApiError(
        422,
        `Votre avis doit faire au moins ${limits.reviewMinChars} caractères.`,
        'VALIDATION_FAILED'
      );
    }
    assertNotBlocked(text);
    const listingId = req.params.id;
    const userId = req.userId!;

    const existing = await prisma.review.findUnique({
      where: { listingId_userId: { listingId, userId } },
    });
    if (existing) throw new ApiError(409, 'Vous avez déjà laissé un avis', 'CONFLICT');

    const review = await prisma.review.create({
      data: { listingId, userId, rating, text },
      include: { user: { select: { id: true, fullName: true, avatarUrl: true } } },
    });

    const agg = await prisma.review.aggregate({
      where: { listingId },
      _avg: { rating: true },
      _count: true,
    });
    await prisma.listing.update({
      where: { id: listingId },
      data: { rating: agg._avg.rating ?? null, reviewCount: agg._count },
    });

    broadcastReview(listingId, review as unknown as Record<string, unknown>);
    res.status(201).json({ review });
  })
);

// Public profile of any user — used by the chat header on iOS so tapping the
// other party opens their profile (name, "Membre depuis", listings, verified
// badge). Deliberately excludes phone, email, and everything else that could
// leak private data across users.
export const usersRouter = Router();

/**
 * DELETE /api/users/me — permanent account deletion.
 *
 * The app offered "Supprimer mon compte" and only signed the user out, while
 * telling them their annonces, favourites and messages were gone. Nothing was.
 *
 * Every relation that belongs to the person cascades from the `User` row
 * (listings, favourites, messages, threads, sessions, refresh tokens), so the
 * single delete is the whole job. Reviews they wrote about other people's
 * spaces cascade too, which is the right call for a deletion request.
 */
usersRouter.delete(
  '/me',
  requireAuth,
  asyncHandler(async (req, res) => {
    const userId = req.userId!;
    // Revoke first: if the delete somehow fails the tokens are already dead,
    // which fails closed rather than leaving a live session on a half-deleted
    // account.
    await prisma.refreshToken.deleteMany({ where: { userId } });
    await prisma.user.delete({ where: { id: userId } });
    res.json({ ok: true });
  })
);

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
