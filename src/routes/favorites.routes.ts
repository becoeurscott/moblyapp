import { Router } from 'express';
import { prisma } from '../lib/prisma';
import { asyncHandler } from '../lib/http';
import { requireAuth } from '../middleware/auth';
import { serializeListing } from '../lib/serialize';

export const favoritesRouter = Router();

const ownerSelect = {
  owner: { select: { id: true, fullName: true, verified: true, rating: true, avatarUrl: true } },
} as const;

/** GET /api/favorites — the user's favorite listings. */
favoritesRouter.get(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const favs = await prisma.favorite.findMany({
      where: { userId: req.userId! },
      include: { listing: { include: ownerSelect } },
      orderBy: { createdAt: 'desc' },
    });
    res.json({ items: favs.map((f) => serializeListing(f.listing)) });
  })
);

/** POST /api/favorites/:listingId — add. */
favoritesRouter.post(
  '/:listingId',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { listingId } = req.params;
    await prisma.favorite.upsert({
      where: { userId_listingId: { userId: req.userId!, listingId } },
      create: { userId: req.userId!, listingId },
      update: {},
    });
    await prisma.listing.update({ where: { id: listingId }, data: { favorites: { increment: 1 } } }).catch(() => {});
    res.json({ favorited: true });
  })
);

/** DELETE /api/favorites/:listingId — remove. */
favoritesRouter.delete(
  '/:listingId',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { listingId } = req.params;
    const deleted = await prisma.favorite
      .delete({ where: { userId_listingId: { userId: req.userId!, listingId } } })
      .catch(() => null);
    if (deleted) {
      await prisma.listing
        .update({ where: { id: listingId }, data: { favorites: { decrement: 1 } } })
        .catch(() => {});
    }
    res.json({ favorited: false });
  })
);
