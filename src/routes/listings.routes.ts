import { Router } from 'express';
import { z } from 'zod';
import { Prisma, DealType, ListingStatus } from '@prisma/client';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { optionalAuth, requireAuth, requireOwner } from '../middleware/auth';
import { serializeListing } from '../lib/serialize';
import { cacheGet, cacheSet, cacheBust } from '../lib/cache';

export const listingsRouter = Router();

/** Namespace for cached listing responses; any write busts the whole prefix. */
const LIST_CACHE = 'listings:';
const LIST_TTL_MS = 60_000;

const ownerSelect = {
  owner: { select: { id: true, fullName: true, verified: true, rating: true, avatarUrl: true } },
} as const;

const PUBLIC_LISTING_STATUSES: ListingStatus[] = [ListingStatus.ACTIVE, ListingStatus.BOOSTED];

/** GET /api/listings — search + filter. Boosted listings float to the top. */
listingsRouter.get(
  '/',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        query: z.string().optional(),
        category: z.string().optional(),
        region: z.string().optional(),
        city: z.string().optional(),
        deal: z.nativeEnum(DealType).optional(),
        furnished: z.enum(['true', 'false']).optional(),
        min: z.coerce.number().optional(),
        max: z.coerce.number().optional(),
        rooms: z.coerce.number().optional(),
        limit: z.coerce.number().min(1).max(500).default(200),
        offset: z.coerce.number().min(0).default(0),
      })
      .parse(req.query);

    // Serve repeat browse traffic from memory — the Supabase round-trip is the
    // dominant cost here (~1.3s fixed), not the query or the payload.
    const cacheKey = LIST_CACHE + JSON.stringify(q);
    const hit = cacheGet(cacheKey);
    if (hit) {
      res.set('X-Cache', 'HIT');
      return res.json(hit);
    }

    const where: Prisma.ListingWhereInput = {
      available: true,
      status: { in: PUBLIC_LISTING_STATUSES },
    };
    if (q.category && q.category !== 'Tous') where.category = q.category;
    if (q.region) where.region = q.region;
    if (q.city) where.city = { contains: q.city, mode: 'insensitive' };
    if (q.deal) where.deal = q.deal;
    if (q.furnished) where.furnished = q.furnished === 'true';
    if (q.rooms !== undefined) where.rooms = { gte: q.rooms };
    if (q.min !== undefined || q.max !== undefined) {
      where.priceFcfa = {};
      if (q.min !== undefined) where.priceFcfa.gte = q.min;
      if (q.max !== undefined) where.priceFcfa.lte = q.max;
    }
    if (q.query) {
      where.OR = [
        { title: { contains: q.query, mode: 'insensitive' } },
        { city: { contains: q.query, mode: 'insensitive' } },
        { neighborhood: { contains: q.query, mode: 'insensitive' } },
        { category: { contains: q.query, mode: 'insensitive' } },
      ];
    }

    const [items, total] = await Promise.all([
      prisma.listing.findMany({
        where,
        include: ownerSelect,
        orderBy: [{ createdAt: 'desc' }],
        skip: q.offset,
        take: q.limit,
      }),
      prisma.listing.count({ where }),
    ]);

    // Ensure boosted really come first regardless of enum ordering.
    items.sort((a, b) => (a.status === 'BOOSTED' ? -1 : 0) - (b.status === 'BOOSTED' ? -1 : 0));

    const payload = { total, items: items.map(serializeListing) };
    cacheSet(cacheKey, payload, LIST_TTL_MS);
    res.set('X-Cache', 'MISS');
    res.json(payload);
  })
);

/** GET /api/listings/:id — one listing (also bumps views + logs a raw
 *  ViewEvent so the owner stats can plot per-day traffic and source mix).
 *  `?source=` is a free-form tag from the client ("home", "explore",
 *  "search", "recommended", "detail-similar"). Owner self-views are not
 *  double-counted so the metric reflects real interest. */
listingsRouter.get(
  '/:id',
  optionalAuth,
  asyncHandler(async (req, res) => {
    const source = typeof req.query.source === 'string'
      ? String(req.query.source).slice(0, 32) : null;
    const listing = await prisma.listing.findUnique({
      where: { id: req.params.id },
      include: ownerSelect,
    }).catch(() => null);
    if (!listing) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
    const publicStatus = PUBLIC_LISTING_STATUSES.includes(listing.status);
    const canSeePrivate = listing.ownerId === req.userId || req.user?.isAdmin === true;
    if ((!listing.available || !publicStatus) && !canSeePrivate) {
      throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
    }
    await prisma.listing.update({
      where: { id: listing.id },
      data: { views: { increment: 1 } },
    });
    // Skip the raw event when the owner is viewing their own annonce —
    // otherwise the "traffic" chart is dominated by the owner refreshing.
    if (listing.ownerId !== req.userId) {
      prisma.viewEvent.create({
        data: { listingId: listing.id, userId: req.userId ?? null, source },
      }).catch(() => {});
    }
    res.json({ listing: serializeListing(listing) });
  })
);

const listingBody = z.object({
  title: z.string().min(1),
  category: z.string().min(1),
  deal: z.nativeEnum(DealType).default(DealType.RENT),
  region: z.string().optional(),
  city: z.string().min(1),
  neighborhood: z.string().optional(),
  priceFcfa: z.number().int().positive(),
  furnished: z.boolean().default(true),
  rooms: z.number().int().min(0).default(1),
  about: z.string().optional(),
  tags: z.array(z.string()).default([]),
  coverUrl: z.string().url().optional(),
  imageName: z.string().optional(),
  photos: z.array(z.string()).default([]),
  lat: z.number().optional(),
  lng: z.number().optional(),
});

/** POST /api/listings — publish (owner). Starts as PENDING review. */
listingsRouter.post(
  '/',
  requireAuth,
  requireOwner,
  asyncHandler(async (req, res) => {
    const body = listingBody.parse(req.body);
    const listing = await prisma.listing.create({
      data: { ...body, ownerId: req.userId!, status: 'PENDING' },
      include: ownerSelect,
    });
    cacheBust(LIST_CACHE);
    res.status(201).json({ listing: serializeListing(listing) });
  })
);

async function assertOwnership(id: string, userId: string) {
  const l = await prisma.listing.findUnique({ where: { id }, select: { ownerId: true } });
  if (!l) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
  if (l.ownerId !== userId)
    throw new ApiError(403, 'Vous ne possédez pas cette annonce', 'FORBIDDEN');
}

/** PATCH /api/listings/:id — edit (owner). */
listingsRouter.patch(
  '/:id',
  requireAuth,
  requireOwner,
  asyncHandler(async (req, res) => {
    await assertOwnership(req.params.id, req.userId!);
    const body = listingBody.partial().parse(req.body);
    const listing = await prisma.listing.update({
      where: { id: req.params.id },
      data: body,
      include: ownerSelect,
    });
    cacheBust(LIST_CACHE);
    res.json({ listing: serializeListing(listing) });
  })
);

/** PATCH /api/listings/:id/availability — toggle disponible/indisponible. */
listingsRouter.patch(
  '/:id/availability',
  requireAuth,
  requireOwner,
  asyncHandler(async (req, res) => {
    await assertOwnership(req.params.id, req.userId!);
    const { available } = z.object({ available: z.boolean() }).parse(req.body);
    const listing = await prisma.listing.update({
      where: { id: req.params.id },
      data: { available },
      include: ownerSelect,
    });
    cacheBust(LIST_CACHE);
    res.json({ listing: serializeListing(listing) });
  })
);

/** DELETE /api/listings/:id — remove (owner). */
listingsRouter.delete(
  '/:id',
  requireAuth,
  requireOwner,
  asyncHandler(async (req, res) => {
    await assertOwnership(req.params.id, req.userId!);
    await prisma.listing.delete({ where: { id: req.params.id } });
    cacheBust(LIST_CACHE);
    res.status(204).end();
  })
);
