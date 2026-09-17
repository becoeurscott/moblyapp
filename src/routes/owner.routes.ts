import { Router } from 'express';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth, requireOwner } from '../middleware/auth';
import { serializeListing, serializeUser } from '../lib/serialize';

export const ownerRouter = Router();

const ownerSelect = {
  owner: {
    select: {
      id: true, fullName: true, verified: true, identityVerified: true, rating: true, avatarUrl: true, avatarColor: true,
      // Needed to compute the owner's "active" state (trial / paid) on each listing.
      isOwner: true, ownerPaid: true, ownerTrialStartedAt: true,
    },
  },
} as const;

/** POST /api/owner/activate — pay the one-time inscription fee.
 *
 *  Called after the client-side mobile-money checkout confirms. Flips
 *  `ownerPaid` so the account is active for good: dashboard unlocked, listings
 *  visible again, contact re-enabled. Idempotent — paying twice is harmless. */
ownerRouter.post(
  '/activate',
  requireAuth,
  requireOwner,
  asyncHandler(async (req, res) => {
    const user = await prisma.user.update({
      where: { id: req.userId! },
      data: { ownerPaid: true },
    });
    res.json({ user: serializeUser(user) });
  })
);

/** GET /api/owner/annonces — the owner's own listings (any status). */
ownerRouter.get(
  '/annonces',
  requireAuth,
  requireOwner,
  asyncHandler(async (req, res) => {
    const items = await prisma.listing.findMany({
      where: { ownerId: req.userId! },
      include: ownerSelect,
      orderBy: { createdAt: 'desc' },
    });
    res.json({ items: items.map(serializeListing) });
  })
);

/** Detail for the overall statistics screen: all-time totals counted from the
 *  event tables (so they only include annonces that still exist — a deleted
 *  annonce takes its events with it), a 30-day daily series, the source mix
 *  and a per-annonce ranking. */
async function overviewDetail(ownerId: string, d30: Date) {
  const mine = { listing: { ownerId } };
  const [viewsAll, contactsAll, favoritesAll, visitsAll, events, contacts, sources, listings] =
    await Promise.all([
      prisma.viewEvent.count({ where: mine }),
      prisma.contactEvent.count({ where: mine }),
      prisma.favorite.count({ where: mine }),
      prisma.visitRequest.count({ where: mine }),
      prisma.viewEvent.findMany({
        where: { ...mine, createdAt: { gte: d30 } },
        select: { createdAt: true, listingId: true },
      }),
      prisma.contactEvent.findMany({
        where: { ...mine, createdAt: { gte: d30 } },
        select: { createdAt: true },
      }),
      prisma.viewEvent.groupBy({
        by: ['source'],
        where: { ...mine, createdAt: { gte: d30 } },
        _count: { _all: true },
      }),
      prisma.listing.findMany({
        where: { ownerId },
        select: {
          id: true, title: true, coverUrl: true, imageName: true, available: true,
          _count: { select: { viewEvents: true, contactEvents: true, favoritedBy: true } },
        },
      }),
    ]);

  // Daily buckets, oldest first. Keyed by UTC date to stay stable server-side.
  const day = (d: Date) => d.toISOString().slice(0, 10);
  const daily: { date: string; views: number; contacts: number }[] = [];
  const index = new Map<string, number>();
  for (let i = 29; i >= 0; i--) {
    const key = day(new Date(Date.now() - i * 24 * 60 * 60 * 1000));
    index.set(key, daily.length);
    daily.push({ date: key, views: 0, contacts: 0 });
  }
  const views30ByListing = new Map<string, number>();
  for (const e of events) {
    const i = index.get(day(e.createdAt));
    if (i !== undefined) daily[i].views++;
    views30ByListing.set(e.listingId, (views30ByListing.get(e.listingId) ?? 0) + 1);
  }
  for (const c of contacts) {
    const i = index.get(day(c.createdAt));
    if (i !== undefined) daily[i].contacts++;
  }

  const KNOWN = new Set([
    'home', 'explore', 'search', 'boost', 'share', 'notification', 'chat',
    'recommended', 'favorites', 'detail-similar', 'profile',
  ]);
  const merged = new Map<string, number>();
  for (const s of sources) {
    const key = s.source && KNOWN.has(s.source) ? s.source : 'other';
    merged.set(key, (merged.get(key) ?? 0) + s._count._all);
  }
  const total = events.length;
  const sources30d = total === 0 ? [] : [...merged.entries()]
    .sort((a, b) => b[1] - a[1])
    .map(([source, count]) => ({ source, count, percent: Math.round((count / total) * 100) }));

  const topListings = listings
    .map((l) => ({
      id: l.id,
      title: l.title,
      coverUrl: l.coverUrl ?? l.imageName,
      available: l.available,
      views: l._count.viewEvents,
      views30d: views30ByListing.get(l.id) ?? 0,
      contacts: l._count.contactEvents,
      favorites: l._count.favoritedBy,
    }))
    .sort((a, b) => b.views - a.views);

  return {
    totals: {
      views: viewsAll,
      contacts: contactsAll,
      favorites: favoritesAll,
      visits: visitsAll,
      contactRate: viewsAll > 0 ? Number(((contactsAll / viewsAll) * 100).toFixed(1)) : 0,
    },
    daily30d: daily,
    sources30d,
    topListings,
  };
}

/** GET /api/owner/overview — aggregate performance + REAL 30-day deltas.
 *
 *  The dashboard used to render "+18% / +9% / +12%" as hardcoded strings next
 *  to these totals. Those are now computed from the raw event tables: the last
 *  30 days against the 30 before that. `deltas30d` is null for a metric with
 *  no prior-period data, so the client can hide the badge instead of inventing
 *  a trend for an annonce published last week. */
ownerRouter.get(
  '/overview',
  requireAuth,
  requireOwner,
  asyncHandler(async (req, res) => {
    const ownerId = req.userId!;
    const agg = await prisma.listing.aggregate({
      where: { ownerId },
      _sum: { views: true, contacts: true, favorites: true },
      _count: true,
    });
    const boosted = await prisma.listing.count({
      where: { ownerId, status: 'BOOSTED' },
    });

    // Window boundaries: [60d..30d) is "previous", [30d..now] is "current".
    const now = Date.now();
    const d30 = new Date(now - 30 * 24 * 60 * 60 * 1000);
    const d60 = new Date(now - 60 * 24 * 60 * 60 * 1000);
    const mine = { listing: { ownerId } };

    const [vNow, vPrev, cNow, cPrev, fNow, fPrev] = await Promise.all([
      prisma.viewEvent.count({    where: { ...mine, createdAt: { gte: d30 } } }),
      prisma.viewEvent.count({    where: { ...mine, createdAt: { gte: d60, lt: d30 } } }),
      prisma.contactEvent.count({ where: { ...mine, createdAt: { gte: d30 } } }),
      prisma.contactEvent.count({ where: { ...mine, createdAt: { gte: d60, lt: d30 } } }),
      prisma.favorite.count({     where: { ...mine, createdAt: { gte: d30 } } }),
      prisma.favorite.count({     where: { ...mine, createdAt: { gte: d60, lt: d30 } } }),
    ]);

    // Same rule as the per-listing stats: no prior-period activity, or a base
    // too small to be meaningful, means there is no trend to report.
    const MIN_BASE = 5;
    const pct = (curr: number, prev: number): number | null =>
      prev < MIN_BASE ? null : Math.round(((curr - prev) / prev) * 100);

    res.json({
      listings: agg._count,
      boosted,
      views: agg._sum.views ?? 0,
      contacts: agg._sum.contacts ?? 0,
      favorites: agg._sum.favorites ?? 0,
      last30d: { views: vNow, contacts: cNow, favorites: fNow },
      deltas30d: {
        views:     pct(vNow, vPrev),
        contacts:  pct(cNow, cPrev),
        favorites: pct(fNow, fPrev),
      },
      ...(await overviewDetail(ownerId, d30)),
    });
  })
);

/** GET /api/owner/stats/:id — per-listing stats.
 *
 *  Computes everything from raw event tables so the numbers stay accurate
 *  even after favorites are un-favorited or spam contacts are deleted. Also
 *  returns a 7-day daily series (Lun→Dim), a delta vs the previous week and
 *  a real "Origine des vues" breakdown from `ViewEvent.source`. */
ownerRouter.get(
  '/stats/:id',
  requireAuth,
  requireOwner,
  asyncHandler(async (req, res) => {
    const listing = await prisma.listing.findUnique({
      where: { id: req.params.id },
      include: ownerSelect,
    });
    if (!listing) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
    if (listing.ownerId !== req.userId!) throw new ApiError(403, 'Non autorisé', 'FORBIDDEN');

    const now = new Date();
    const startOfDay = (d: Date) => {
      const c = new Date(d); c.setHours(0, 0, 0, 0); return c;
    };
    const sevenAgo = new Date(startOfDay(now)); sevenAgo.setDate(sevenAgo.getDate() - 6);
    const fourteenAgo = new Date(startOfDay(now)); fourteenAgo.setDate(fourteenAgo.getDate() - 13);

    const [
      viewsAll, contactsAll, favoritesAll, visitsAll,
      viewsThis, viewsPrev, contactsThis, contactsPrev, favsThis, favsPrev,
      viewEvents, sources,
    ] = await Promise.all([
      prisma.viewEvent.count({ where: { listingId: listing.id } }),
      prisma.contactEvent.count({ where: { listingId: listing.id } }),
      prisma.favorite.count({ where: { listingId: listing.id } }),
      prisma.visitRequest.count({ where: { listingId: listing.id } }),
      prisma.viewEvent.count({ where: { listingId: listing.id, createdAt: { gte: sevenAgo } } }),
      prisma.viewEvent.count({ where: { listingId: listing.id,
                                        createdAt: { gte: fourteenAgo, lt: sevenAgo } } }),
      prisma.contactEvent.count({ where: { listingId: listing.id, createdAt: { gte: sevenAgo } } }),
      prisma.contactEvent.count({ where: { listingId: listing.id,
                                           createdAt: { gte: fourteenAgo, lt: sevenAgo } } }),
      prisma.favorite.count({ where: { listingId: listing.id, createdAt: { gte: sevenAgo } } }),
      prisma.favorite.count({ where: { listingId: listing.id,
                                       createdAt: { gte: fourteenAgo, lt: sevenAgo } } }),
      prisma.viewEvent.findMany({
        where: { listingId: listing.id, createdAt: { gte: sevenAgo } },
        select: { createdAt: true, source: true },
      }),
      prisma.viewEvent.groupBy({
        by: ['source'],
        where: { listingId: listing.id, createdAt: { gte: sevenAgo } },
        _count: { _all: true },
      }),
    ]);

    // 7-day series bucketed by local day. Keep labels short (FR weekday
    // abbreviations) so the client chart doesn't have to re-derive them.
    const labels = ['Lun','Mar','Mer','Jeu','Ven','Sam','Dim'];
    const daily: { date: string; label: string; views: number }[] = [];
    for (let i = 6; i >= 0; i--) {
      const d = new Date(startOfDay(now)); d.setDate(d.getDate() - i);
      const next = new Date(d); next.setDate(next.getDate() + 1);
      const c = viewEvents.filter((e) => e.createdAt >= d && e.createdAt < next).length;
      const label = labels[(d.getDay() + 6) % 7]; // Monday = 0
      daily.push({ date: d.toISOString(), label, views: c });
    }

    // "Origine des vues": normalise unknown/null into "Autre" so the chart
    // always sums to the visible total. Percentages are rounded to whole
    // integers and the largest bucket absorbs the rounding drift.
    // Untagged views (null, or the generic "detail" from older app builds)
    // are merged into one "other" row, and the list is sorted largest first.
    const KNOWN = new Set([
      'home', 'explore', 'search', 'boost', 'share', 'notification', 'chat',
      'recommended', 'favorites', 'detail-similar', 'profile',
    ]);
    const merged = new Map<string, number>();
    for (const s of sources) {
      const key = s.source && KNOWN.has(s.source) ? s.source : 'other';
      merged.set(key, (merged.get(key) ?? 0) + s._count._all);
    }
    const total = sources.reduce((n, s) => n + s._count._all, 0);
    const sourceBreakdown = (total === 0 ? [] : [...merged.entries()]
      .sort((x, y) => y[1] - x[1])
      .map(([source, count]) => ({
        source,
        count,
        percent: Math.round((count / total) * 100),
      })));

    // A percentage off a tiny base is noise, not a trend: 1 view last week and
    // 62 this week is a true "+6100%" and a useless thing to show an owner.
    // Below MIN_BASE there is no comparison worth making, so return null and
    // let the client render no badge at all.
    const MIN_BASE = 5;
    const pct = (curr: number, prev: number): number | null =>
      prev < MIN_BASE ? null : Math.round(((curr - prev) / prev) * 100);

    const contactRate = viewsAll > 0 ? contactsAll / viewsAll : 0;
    res.json({
      listing: serializeListing(listing),
      metrics: {
        views: viewsAll,
        contacts: contactsAll,
        favorites: favoritesAll,
        visits: visitsAll,
        contactRate: Number((contactRate * 100).toFixed(1)),
        deltas7d: {
          views:     pct(viewsThis, viewsPrev),
          contacts:  pct(contactsThis, contactsPrev),
          favorites: pct(favsThis, favsPrev),
        },
      },
      daily,
      sources: sourceBreakdown,
      generatedAt: now.toISOString(),
    });
  })
);
