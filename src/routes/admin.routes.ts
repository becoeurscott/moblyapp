import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth, requireAdmin, requirePermission } from '../middleware/auth';
import { can } from '../lib/permissions';
import { audit, diff } from '../lib/audit';
import { cacheBust } from '../lib/cache';
import { notifyNewListing } from '../services/listingNotify';
import { notifyUser, pushConfigured } from '../services/push';
import { serializeMessage } from '../lib/serialize';
import { broadcastMessage } from '../realtime/hub';
import { configSnapshot } from '../services/config';
import { OWNER_STATUSES, OWNER_TRIAL_DAYS, ownerStatusWhere, ownerStatusOf } from '../lib/ownerTrial';
import { adminIpGate, adminWriteLimiter, requireConfirmation } from '../middleware/adminSecurity';
import { adminUsersRouter } from './admin/users.routes';
import { adminConfigRouter } from './admin/config.routes';
import { adminModerationRouter } from './admin/moderation.routes';
import { adminSecurityRouter } from './admin/security.routes';
import { adminSystemRouter } from './admin/system.routes';
import { adminSupportRouter } from './admin/support.routes';

export const adminRouter = Router();

/**
 * Order matters here. Identify the caller, confirm they are an admin, then
 * check where they are calling from and how fast — an IP check is meaningless
 * before we know who is asking, and rate limiting an anonymous request would
 * let one attacker exhaust an admin's quota.
 */
adminRouter.use(requireAuth, requireAdmin, adminIpGate, adminWriteLimiter);

// Remote-control surface, split by concern. Mounted before the legacy routes
// below so the more specific paths (/users/:id/restrictions) are matched by
// their own router rather than falling into the generic handlers.
adminRouter.use('/config', adminConfigRouter);
adminRouter.use('/security', adminSecurityRouter);
adminRouter.use('/system', adminSystemRouter);
adminRouter.use('/moderation', adminModerationRouter);
adminRouter.use('/support', adminSupportRouter);
adminRouter.use('/users', adminUsersRouter);
adminRouter.use('/restrictions', adminUsersRouter);

/** Latest in-app ratings submitted by users. */
adminRouter.get('/app-ratings', asyncHandler(async (_req, res) => {
  const [items, total, average] = await Promise.all([
    prisma.appRating.findMany({
      orderBy: { submittedAt: 'desc' },
      take: 500,
      include: { user: { select: { id: true, fullName: true, phone: true, email: true, city: true } } },
    }),
    prisma.appRating.count(),
    prisma.appRating.aggregate({ _avg: { rating: true } }),
  ]);
  res.json({ total, average: average._avg.rating ?? 0, items });
}));

/** Ask a user to rate Mobly again on their next Home visit. */
adminRouter.post('/app-ratings/:userId/request-again', asyncHandler(async (req, res) => {
  const user = await prisma.user.findUnique({ where: { id: req.params.userId }, select: { id: true } });
  if (!user) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');
  await prisma.appRating.upsert({
    where: { userId: user.id },
    create: { userId: user.id, rating: null, promptAgain: true },
    update: { promptAgain: true },
  });
  await notifyUser({
    userId: user.id,
    type: 'APP_RATING_REQUEST',
    title: 'Votre avis compte',
    body: 'Dites-nous comment améliorer Mobly.',
    payload: { action: 'app_rating' },
  });
  res.json({ ok: true });
}));

// ═════════════════════════════════════════════════════════════
// Overview + analytics
// ═════════════════════════════════════════════════════════════

/** Range filter shared by the dashboard: 1 sem · 1 mois · 3 mois · 6 mois · 1 an. */
const RANGE_DAYS = [7, 30, 90, 180, 365] as const;
function parseRangeDays(raw: unknown): number {
  const n = Number(raw);
  return (RANGE_DAYS as readonly number[]).includes(n) ? n : 30;
}

/** GET /api/admin/overview — top-line KPIs for the dashboard home. */
adminRouter.get(
  '/overview',
  asyncHandler(async (req, res) => {
    const now = Date.now();
    const day = 24 * 60 * 60 * 1000;
    const since24h = new Date(now - day);
    const since30d = new Date(now - 30 * day);
    const days = parseRangeDays(req.query.days);
    const sinceRange = new Date(now - days * day);

    const [
      users, owners, activeSessions24h,
      listings, pendingListings, boostedListings,
      openReports,
      pendingVisits, confirmedVisits,
      threads, messagesLast24h,
    ] = await Promise.all([
      prisma.user.count(),
      prisma.user.count({ where: { isOwner: true } }),
      prisma.appSession.count({ where: { lastActiveAt: { gte: since24h } } }),
      prisma.listing.count(),
      prisma.listing.count({ where: { status: 'PENDING' } }),
      prisma.listing.count({ where: { status: 'BOOSTED' } }),
      prisma.report.count({ where: { status: { in: ['OPEN', 'REVIEWING'] } } }),
      prisma.visitRequest.count({ where: { status: 'REQUESTED' } }),
      prisma.visitRequest.count({ where: { status: 'CONFIRMED', scheduledAt: { gte: new Date() } } }),
      prisma.thread.count(),
      prisma.message.count({ where: { createdAt: { gte: since24h } } }),
    ]);

    const newUsers30d = await prisma.user.count({ where: { createdAt: { gte: since30d } } });
    const newListings30d = await prisma.listing.count({ where: { createdAt: { gte: since30d } } });
    const [newUsersRange, newListingsRange] = await Promise.all([
      prisma.user.count({ where: { createdAt: { gte: sinceRange } } }),
      prisma.listing.count({ where: { createdAt: { gte: sinceRange } } }),
    ]);

    res.json({
      rangeDays: days, newUsersRange, newListingsRange,
      users, owners, newUsers30d,
      listings, pendingListings, boostedListings, newListings30d,
      activeSessions24h,
      openReports,
      pendingVisits, confirmedVisits,
      threads, messagesLast24h,
    });
  })
);

/** GET /api/admin/analytics/summary — DAU/MAU + top events, last 30 days. */
adminRouter.get(
  '/analytics/summary',
  asyncHandler(async (req, res) => {
    const now = Date.now();
    const day = 24 * 60 * 60 * 1000;
    const days = parseRangeDays(req.query.days);

    // Two GROUP BY queries instead of a pair of count() calls per day: the
    // old loop issued 60 queries per request, which on its own could exhaust
    // a small connection pool (P2024) when several admin pages load at once.
    // Days are bucketed in UTC on both sides so the keys line up exactly.
    const since = new Date(now - days * day);
    since.setUTCHours(0, 0, 0, 0);
    const [sessRows, evRows] = await Promise.all([
      prisma.$queryRaw<{ d: string; n: number }[]>`
        SELECT to_char(date_trunc('day', "startedAt"), 'YYYY-MM-DD') AS d, COUNT(*)::int AS n
        FROM "AppSession" WHERE "startedAt" >= ${since} GROUP BY 1`,
      prisma.$queryRaw<{ d: string; n: number }[]>`
        SELECT to_char(date_trunc('day', "createdAt"), 'YYYY-MM-DD') AS d, COUNT(*)::int AS n
        FROM "AppEvent" WHERE "createdAt" >= ${since} GROUP BY 1`,
    ]);
    const sessBy = new Map(sessRows.map((r) => [r.d, r.n]));
    const evBy = new Map(evRows.map((r) => [r.d, r.n]));

    const dayBuckets: { day: string; sessions: number; events: number }[] = [];
    for (let i = days - 1; i >= 0; i--) {
      const start = new Date(now - i * day);
      start.setUTCHours(0, 0, 0, 0);
      const k = start.toISOString().slice(0, 10);
      dayBuckets.push({ day: k, sessions: sessBy.get(k) ?? 0, events: evBy.get(k) ?? 0 });
    }

    const since30d = new Date(now - 30 * day);
    const since1d = new Date(now - day);
    const dau = await prisma.appSession.groupBy({
      by: ['userId'],
      where: { userId: { not: null }, lastActiveAt: { gte: since1d } },
    });
    const mau = await prisma.appSession.groupBy({
      by: ['userId'],
      where: { userId: { not: null }, lastActiveAt: { gte: since30d } },
    });

    const topEvents = await prisma.appEvent.groupBy({
      by: ['name'],
      where: { createdAt: { gte: since30d } },
      _count: { _all: true },
      orderBy: { _count: { name: 'desc' } },
      take: 10,
    });

    res.json({
      rangeDays: days,
      dailyBuckets: dayBuckets,
      dau: dau.length,
      mau: mau.length,
      topEvents: topEvents.map((e) => ({ name: e.name, count: e._count._all })),
    });
  })
);

// ═════════════════════════════════════════════════════════════
// Users
// ═════════════════════════════════════════════════════════════

const userSummarySelect = {
  id: true,
  fullName: true,
  email: true,
  phone: true,
  isOwner: true,
  isAdmin: true,
  isActive: true,
  verified: true,
  identityVerified: true,
  city: true,
  avatarUrl: true,
  avatarColor: true,
  createdAt: true,
  lastSeenAt: true,
  ownerPaid: true,
  ownerTrialStartedAt: true,
} as const;

/** GET /api/admin/users — paginated, search, filter.
 *
 *  `ownerStatus` narrows to owners in one trial state (see `ownerStatusWhere`).
 *  Every page also carries `ownerCounts` — one aggregate query — so the
 *  dashboard's filter chips can show how many owners sit in each state. */
adminRouter.get(
  '/users',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        query: z.string().optional(),
        role: z.enum(['all', 'owner', 'visitor', 'admin']).optional(),
        active: z.enum(['all', 'active', 'suspended']).optional(),
        ownerStatus: z.enum(['all', ...OWNER_STATUSES]).optional(),
        page: z.coerce.number().int().min(0).optional(),
        pageSize: z.coerce.number().int().min(1).max(100).optional(),
      })
      .safeParse(req.query);
    if (!q.success) throw new ApiError(400, 'Filtres invalides', 'VALIDATION_FAILED');

    const search = q.data.query?.trim();
    const where: any = {};
    if (search && search.length > 0) {
      // Phones are stored as "+2376XXXXXXXX"; an operator types "6 99 00 00 01"
      // or "+237 699…" — compare on digits only so either form matches.
      const digits = search.replace(/\D/g, '');
      where.OR = [
        { fullName: { contains: search, mode: 'insensitive' } },
        { email: { contains: search, mode: 'insensitive' } },
        { phone: { contains: digits.length >= 3 ? digits : search } },
      ];
    }
    if (q.data.role === 'owner') where.isOwner = true;
    if (q.data.role === 'visitor') where.isOwner = false;
    if (q.data.role === 'admin') where.isAdmin = true;
    if (q.data.active === 'active') where.isActive = true;
    if (q.data.active === 'suspended') where.isActive = false;
    // AND-ed rather than spread: `where.OR` may already hold the search.
    if (q.data.ownerStatus && q.data.ownerStatus !== 'all') {
      where.AND = [ownerStatusWhere(q.data.ownerStatus)];
    }

    const page = q.data.page ?? 0;
    const pageSize = q.data.pageSize ?? 20;
    const cutoff = new Date(Date.now() - OWNER_TRIAL_DAYS * 24 * 60 * 60 * 1000);

    const [total, items, [counts]] = await Promise.all([
      prisma.user.count({ where }),
      prisma.user.findMany({
        where,
        select: userSummarySelect,
        orderBy: { createdAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
      }),
      prisma.$queryRaw<{ trial: number; locked: number; paid: number; grandfathered: number }[]>`
        SELECT
          COUNT(*) FILTER (WHERE NOT "ownerPaid" AND "ownerTrialStartedAt" >= ${cutoff})::int AS "trial",
          COUNT(*) FILTER (WHERE NOT "ownerPaid" AND "ownerTrialStartedAt" < ${cutoff})::int AS "locked",
          COUNT(*) FILTER (WHERE "ownerPaid")::int AS "paid",
          COUNT(*) FILTER (WHERE NOT "ownerPaid" AND "ownerTrialStartedAt" IS NULL)::int AS "grandfathered"
        FROM "User" WHERE "isOwner" = true`,
    ]);

    res.json({
      total, page, pageSize,
      items: items.map((u) => ({ ...u, ownerStatus: ownerStatusOf(u) })),
      ownerCounts: counts ?? { trial: 0, locked: 0, paid: 0, grandfathered: 0 },
    });
  })
);

/** GET /api/admin/users/:id — full detail + activity counts. */
adminRouter.get(
  '/users/:id',
  asyncHandler(async (req, res) => {
    const user = await prisma.user.findUnique({
      where: { id: req.params.id },
      select: {
        ...userSummarySelect,
        bio: true,
        region: true,
        neighborhood: true,
        moblyScore: true,
        rating: true,
        responseRate: true,
        _count: {
          select: {
            listings: true,
            favorites: true,
            reviews: true,
            reviewsReceived: true,
            messages: true,
            visitsRequested: true,
            visitsReceived: true,
            sessions: true,
            events: true,
          },
        },
      },
    });
    if (!user) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');
    res.json({ user });
  })
);

/** PATCH /api/admin/users/:id — verify / suspend / promote / demote. */
adminRouter.patch(
  '/users/:id',
  asyncHandler(async (req, res) => {
    const body = z
      .object({
        isActive: z.boolean().optional(),
        verified: z.boolean().optional(),
        identityVerified: z.boolean().optional(),
        isOwner: z.boolean().optional(),
        isAdmin: z.boolean().optional(),
      })
      .safeParse(req.body);
    if (!body.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');
    // Guard against an admin locking themselves out.
    if (req.params.id === req.userId! && body.data.isAdmin === false) {
      throw new ApiError(400, 'Impossible de retirer vos propres droits admin', 'VALIDATION_FAILED');
    }
    const user = await prisma.user.update({
      where: { id: req.params.id },
      data: body.data,
      select: userSummarySelect,
    });
    res.json({ user });
  })
);

/**
 * DELETE /api/admin/users/:id — permanent removal (Prisma cascades listings,
 * messages…).
 *
 * Guarded exactly like `/users/:id/anonymize`: this is the *more* destructive
 * of the two — the rows are gone, and reviews and threads other people relied
 * on go with them — so it must not be the easier one to trigger. The audit
 * entry is written *before* the delete, since afterwards there is no row left
 * to describe.
 */
adminRouter.delete(
  '/users/:id',
  requirePermission('user.delete'),
  requireConfirmation((req) => req.params.id),
  asyncHandler(async (req, res) => {
    if (req.params.id === req.userId!) {
      throw new ApiError(400, 'Impossible de supprimer votre propre compte ici', 'VALIDATION_FAILED');
    }

    const target = await prisma.user.findUnique({
      where: { id: req.params.id },
      select: { id: true, fullName: true, phone: true, email: true },
    });
    if (!target) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');

    await audit(req, {
      action: 'user.delete',
      targetType: 'user',
      targetId: target.id,
      before: target,
    });

    await prisma.user.delete({ where: { id: target.id } }).catch(() => {
      throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');
    });
    res.json({ deleted: true });
  })
);

// ═════════════════════════════════════════════════════════════
// Identity checks (KYC queue across every user)
// ═════════════════════════════════════════════════════════════

/** Queue groups the dashboard tabs map to. */
const IDENTITY_GROUPS = {
  open: ['PENDING', 'IN_REVIEW'],
  closed: ['DECLINED', 'ABANDONED'],
  approved: ['APPROVED'],
} as const;

/**
 * GET /api/admin/identity-checks?status=open|closed|approved|all|<STATUS>
 *
 * The verification queue. `open` (the default) lists waiting checks oldest
 * first — first come, first served; the other views are newest first, and
 * `approved` only reaches back 30 days. Each row says whether it is the user's
 * latest check, because the decision endpoint (`POST /users/:id/identity`)
 * always acts on the latest one — acting from an older row would decide a
 * different check than the one on screen.
 */
adminRouter.get(
  '/identity-checks',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        status: z
          .enum(['open', 'closed', 'approved', 'all', 'PENDING', 'IN_REVIEW', 'APPROVED', 'DECLINED', 'ABANDONED'])
          .default('open'),
        query: z.string().optional(),
        page: z.coerce.number().int().min(0).default(0),
        pageSize: z.coerce.number().int().min(1).max(100).default(30),
      })
      .safeParse(req.query);
    if (!q.success) throw new ApiError(400, 'Filtres invalides', 'VALIDATION_FAILED');
    const { status, query, page, pageSize } = q.data;

    const where: any = {};
    if (status in IDENTITY_GROUPS) {
      where.status = { in: [...IDENTITY_GROUPS[status as keyof typeof IDENTITY_GROUPS]] };
    } else if (status !== 'all') {
      where.status = status;
    }
    if (status === 'approved') {
      // "Recent" = requested or decided in the last 30 days.
      const since = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
      where.OR = [{ createdAt: { gte: since } }, { decidedAt: { gte: since } }];
    }
    const search = query?.trim();
    if (search) {
      const digits = search.replace(/\D/g, '');
      where.user = {
        OR: [
          { fullName: { contains: search, mode: 'insensitive' } },
          { email: { contains: search, mode: 'insensitive' } },
          { phone: { contains: digits.length >= 3 ? digits : search } },
        ],
      };
    }

    const [total, items, grouped] = await Promise.all([
      prisma.identityCheck.count({ where }),
      prisma.identityCheck.findMany({
        where,
        orderBy: { createdAt: status === 'open' ? 'asc' : 'desc' },
        skip: page * pageSize,
        take: pageSize,
        include: {
          user: {
            select: {
              id: true, fullName: true, phone: true, email: true,
              avatarUrl: true, avatarColor: true, isOwner: true, identityVerified: true,
            },
          },
        },
      }),
      prisma.identityCheck.groupBy({ by: ['status'], _count: { _all: true } }),
    ]);

    const userIds = [...new Set(items.map((c) => c.userId))];
    const deciderIds = [...new Set(items.map((c) => c.decidedBy).filter((x): x is string => !!x))];
    const [latest, deciders] = await Promise.all([
      prisma.identityCheck.findMany({
        where: { userId: { in: userIds } },
        orderBy: [{ userId: 'asc' }, { createdAt: 'desc' }],
        distinct: ['userId'],
        select: { id: true },
      }),
      prisma.user.findMany({ where: { id: { in: deciderIds } }, select: { id: true, fullName: true } }),
    ]);
    const latestIds = new Set(latest.map((l) => l.id));
    const deciderName = new Map(deciders.map((d) => [d.id, d.fullName]));

    const counts: Record<string, number> = {};
    for (const g of grouped) counts[g.status] = g._count._all;

    res.json({
      total, page, pageSize,
      counts,
      items: items.map(({ hostedUrl: _hostedUrl, ...c }) => ({
        ...c,
        isLatest: latestIds.has(c.id),
        decidedByName: c.decidedBy ? deciderName.get(c.decidedBy) ?? null : null,
      })),
    });
  })
);

// ═════════════════════════════════════════════════════════════
// Listings
// ═════════════════════════════════════════════════════════════

const listingSummarySelect = {
  id: true,
  title: true,
  category: true,
  status: true,
  available: true,
  verified: true,
  city: true,
  neighborhood: true,
  priceFcfa: true,
  priceUnit: true,
  coverUrl: true,
  imageName: true,
  views: true,
  contacts: true,
  favorites: true,
  createdAt: true,
  ownerId: true,
  owner: {
    select: { id: true, fullName: true, avatarUrl: true, avatarColor: true },
  },
} as const;

/** GET /api/admin/listings — paginated, search, filter. */
adminRouter.get(
  '/listings',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        query: z.string().optional(),
        status: z.string().optional(),
        category: z.string().optional(),
        city: z.string().optional(),
        page: z.coerce.number().int().min(0).optional(),
        pageSize: z.coerce.number().int().min(1).max(100).optional(),
      })
      .safeParse(req.query);
    if (!q.success) throw new ApiError(400, 'Filtres invalides', 'VALIDATION_FAILED');

    const search = q.data.query?.trim();
    const where: any = {};
    if (search && search.length > 0) {
      where.OR = [
        { title: { contains: search, mode: 'insensitive' } },
        { neighborhood: { contains: search, mode: 'insensitive' } },
        { city: { contains: search, mode: 'insensitive' } },
      ];
    }
    if (q.data.status && q.data.status !== 'all') where.status = q.data.status;
    // Partial, case-insensitive — an operator types "douala" or "appart".
    if (q.data.category && q.data.category !== 'all') where.category = { contains: q.data.category.trim(), mode: 'insensitive' };
    if (q.data.city && q.data.city !== 'all') where.city = { contains: q.data.city.trim(), mode: 'insensitive' };

    const page = q.data.page ?? 0;
    const pageSize = q.data.pageSize ?? 20;

    const [total, items] = await Promise.all([
      prisma.listing.count({ where }),
      prisma.listing.findMany({
        where,
        select: listingSummarySelect,
        orderBy: { createdAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
      }),
    ]);

    res.json({ total, page, pageSize, items });
  })
);

/** Every column an operator may change on a listing, validated. */
const listingEditable = z.object({
  // moderation (listing.moderate)
  status: z.enum(['DRAFT', 'PENDING', 'ACTIVE', 'BOOSTED', 'PAUSED', 'REJECTED', 'ARCHIVED']).optional(),
  available: z.boolean().optional(),
  verified: z.boolean().optional(),
  adminNote: z.string().max(2000).nullish(),
  // content (listing.edit)
  title: z.string().trim().min(1).max(160).optional(),
  category: z.string().trim().min(1).max(60).optional(),
  deal: z.enum(['RENT', 'BUY', 'SHORT']).optional(),
  about: z.string().max(5000).nullish(),
  region: z.string().max(80).nullish(),
  city: z.string().trim().min(1).max(80).optional(),
  neighborhood: z.string().max(80).nullish(),
  address: z.string().max(200).nullish(),
  lat: z.number().min(-90).max(90).nullish(),
  lng: z.number().min(-180).max(180).nullish(),
  priceFcfa: z.number().int().min(0).max(10_000_000_000).optional(),
  priceUnit: z.enum(['PER_MONTH', 'PER_DAY', 'TOTAL']).optional(),
  negotiable: z.boolean().optional(),
  furnished: z.boolean().optional(),
  rooms: z.number().int().min(0).max(100).optional(),
  bathrooms: z.number().int().min(0).max(100).nullish(),
  sizeSqm: z.number().int().min(0).max(1_000_000).nullish(),
  minDurationMonths: z.number().int().min(0).max(120).nullish(),
  availableFrom: z.coerce.date().nullish(),
  tags: z.array(z.string().trim().min(1).max(40)).max(40).optional(),
  photos: z.array(z.string().url()).max(60).optional(),
  coverUrl: z.string().url().nullish(),
  rating: z.number().min(0).max(5).nullish(),
});

const MODERATION_KEYS = new Set(['status', 'available', 'verified', 'adminNote']);

const listingDetailSelect = {
  id: true, title: true, category: true, deal: true, status: true,
  region: true, city: true, neighborhood: true, address: true, lat: true, lng: true,
  priceFcfa: true, priceUnit: true, currency: true, negotiable: true, furnished: true,
  rooms: true, bathrooms: true, sizeSqm: true, minDurationMonths: true,
  about: true, tags: true, coverUrl: true, imageName: true, photos: true,
  verified: true, rating: true, reviewCount: true, available: true, availableFrom: true,
  views: true, contacts: true, favorites: true,
  boostDaysLeft: true, boostExpiresAt: true, pinnedAt: true, pinnedUntil: true,
  adminNote: true, publishedAt: true, archivedAt: true, createdAt: true, updatedAt: true,
  ownerId: true,
  owner: { select: { id: true, fullName: true, phone: true, email: true, avatarUrl: true, avatarColor: true } },
} as const;

/** GET /api/admin/listings/:id — every editable field, for the edit form. */
adminRouter.get(
  '/listings/:id',
  asyncHandler(async (req, res) => {
    const listing = await prisma.listing.findUnique({ where: { id: req.params.id }, select: listingDetailSelect });
    if (!listing) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
    res.json({ listing });
  })
);

/** PATCH /api/admin/listings/:id — edit any field.
 *
 *  Moderation fields (status, availability, verified badge, note) need
 *  `listing.moderate`; anything that rewrites the annonce itself needs
 *  `listing.edit`. Every change is audited and busts the public feed cache so
 *  the app shows the edit on its next fetch. */
adminRouter.patch(
  '/listings/:id',
  requirePermission('listing.moderate'),
  asyncHandler(async (req, res) => {
    const parsed = listingEditable.safeParse(req.body);
    if (!parsed.success) {
      throw new ApiError(400, parsed.error.issues[0]?.message ?? 'Données invalides', 'VALIDATION_FAILED');
    }
    const patch = parsed.data;
    const role = req.user?.adminRole ?? (req.user?.isAdmin ? 'READ_ONLY' : null);
    if (Object.keys(patch).some((k) => !MODERATION_KEYS.has(k)) && !can(role, 'listing.edit')) {
      throw new ApiError(403, "Votre rôle ne permet pas de modifier le contenu de l'annonce.", 'ROLE_REQUIRED');
    }

    const before = await prisma.listing.findUnique({ where: { id: req.params.id }, select: listingDetailSelect });
    if (!before) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');

    const data: Record<string, unknown> = { ...patch };
    // Keep the lifecycle timestamps coherent with the status an admin sets.
    if (patch.status === 'ACTIVE' && !before.publishedAt) data.publishedAt = new Date();
    if (patch.status === 'ARCHIVED' && !before.archivedAt) data.archivedAt = new Date();
    if (patch.status && patch.status !== 'ARCHIVED' && before.archivedAt) data.archivedAt = null;
    // A cover that isn't in the gallery would render nowhere in the app.
    if (patch.photos && !patch.coverUrl && before.coverUrl && !patch.photos.includes(before.coverUrl)) {
      data.coverUrl = patch.photos[0] ?? null;
    }

    const after = await prisma.listing.update({ where: { id: req.params.id }, data, select: listingDetailSelect });

    await audit(req, { action: 'listing.edit', targetType: 'listing', targetId: after.id, ...diff(before, after, patch) });
    cacheBust('listings:');

    // When a listing goes ACTIVE for the first time, notify users in the same city.
    if (patch.status === 'ACTIVE' && before.status !== 'ACTIVE') {
      notifyNewListing(after as any, before.ownerId).catch(() => {});
    }

    res.json({ listing: after });
  })
);

/** DELETE /api/admin/listings/:id. */
adminRouter.delete(
  '/listings/:id',
  requirePermission('listing.delete'),
  asyncHandler(async (req, res) => {
    const before = await prisma.listing.findUnique({ where: { id: req.params.id }, select: { id: true, title: true, ownerId: true } });
    if (!before) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
    await prisma.listing.delete({ where: { id: req.params.id } });
    await audit(req, { action: 'listing.delete', targetType: 'listing', targetId: before.id, before });
    cacheBust('listings:');
    res.json({ deleted: true });
  })
);

// ═════════════════════════════════════════════════════════════
// Reports
// ═════════════════════════════════════════════════════════════

/** GET /api/admin/reports — moderation queue. */
adminRouter.get(
  '/reports',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        status: z.enum(['OPEN', 'REVIEWING', 'ACTIONED', 'DISMISSED', 'all']).optional(),
        page: z.coerce.number().int().min(0).optional(),
        pageSize: z.coerce.number().int().min(1).max(100).optional(),
      })
      .safeParse(req.query);
    if (!q.success) throw new ApiError(400, 'Filtres invalides', 'VALIDATION_FAILED');

    const where: any = {};
    if (q.data.status && q.data.status !== 'all') where.status = q.data.status;

    const page = q.data.page ?? 0;
    const pageSize = q.data.pageSize ?? 25;

    const [total, items] = await Promise.all([
      prisma.report.count({ where }),
      prisma.report.findMany({
        where,
        orderBy: { createdAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
        include: {
          reporter: { select: { id: true, fullName: true, email: true, phone: true } },
        },
      }),
    ]);

    res.json({ total, page, pageSize, items });
  })
);

/** PATCH /api/admin/reports/:id — action or dismiss. */
adminRouter.patch(
  '/reports/:id',
  asyncHandler(async (req, res) => {
    const body = z
      .object({
        status: z.enum(['OPEN', 'REVIEWING', 'ACTIONED', 'DISMISSED']),
        resolution: z.string().max(500).optional(),
      })
      .safeParse(req.body);
    if (!body.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');
    const report = await prisma.report.update({
      where: { id: req.params.id },
      data: {
        status: body.data.status,
        resolution: body.data.resolution,
        resolvedAt: body.data.status === 'ACTIONED' || body.data.status === 'DISMISSED'
          ? new Date() : null,
      },
    });
    res.json({ report });
  })
);

// ═════════════════════════════════════════════════════════════
// Chat moderation
// ═════════════════════════════════════════════════════════════

/** GET /api/admin/threads — all conversations, newest activity first. */
adminRouter.get(
  '/threads',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        query: z.string().optional(),
        /** Only conversations this user takes part in (the "by user" view). */
        userId: z.string().optional(),
        /** Only conversations about an Airbnb-imported listing — the section
         *  where Mobly staff answer on the imported owner's behalf. */
        imported: z.coerce.boolean().optional(),
        page: z.coerce.number().int().min(0).optional(),
        pageSize: z.coerce.number().int().min(1).max(100).optional(),
      })
      .safeParse(req.query);
    if (!q.success) throw new ApiError(400, 'Filtres invalides', 'VALIDATION_FAILED');

    const search = q.data.query?.trim();
    const where: any = {};
    if (q.data.userId) {
      where.participants = { some: { userId: q.data.userId } };
    }
    if (q.data.imported) {
      where.listing = { tags: { has: 'airbnb-import' } };
    }
    if (search && search.length > 0) {
      const digits = search.replace(/\D/g, '');
      where.OR = [
        { listing: { title: { contains: search, mode: 'insensitive' } } },
        {
          participants: {
            some: {
              user: {
                OR: [
                  { fullName: { contains: search, mode: 'insensitive' } },
                  { email: { contains: search, mode: 'insensitive' } },
                  { phone: { contains: digits.length >= 3 ? digits : search } },
                ],
              },
            },
          },
        },
      ];
    }
    const page = q.data.page ?? 0;
    const pageSize = q.data.pageSize ?? 30;

    const [total, items] = await Promise.all([
      prisma.thread.count({ where }),
      prisma.thread.findMany({
        where,
        orderBy: { updatedAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
        include: {
          listing: { select: { id: true, title: true, imageName: true, coverUrl: true, ownerId: true, tags: true } },
          participants: {
            include: {
              user: {
                select: { id: true, fullName: true, avatarUrl: true, avatarColor: true },
              },
            },
          },
          _count: { select: { messages: true } },
          messages: {
            orderBy: { createdAt: 'desc' },
            take: 1,
            select: { text: true, kind: true, createdAt: true },
          },
        },
      }),
    ]);

    res.json({
      total, page, pageSize,
      items: items.map((t) => {
        const imported = t.listing?.tags?.includes('airbnb-import') ?? false;
        return {
          id: t.id,
          // Drop the heavy tags array from the row; expose the two things the
          // imported-conversations section needs: the flag and who to reply as.
          listing: t.listing
            ? { id: t.listing.id, title: t.listing.title, imageName: t.listing.imageName,
                coverUrl: t.listing.coverUrl, ownerId: t.listing.ownerId }
            : null,
          imported,
          ownerId: t.listing?.ownerId ?? null,
          // `muted` is per participant (push alerts silenced) — the moderation
          // pane toggles it through POST /moderation/threads/:id/mute.
          participants: t.participants.map((p) => ({ ...p.user, muted: p.muted })),
          messageCount: t._count.messages,
          lastMessage: t.messages[0] ?? null,
          frozenAt: t.frozenAt,
          frozenReason: t.frozenReason,
          updatedAt: t.updatedAt,
        };
      }),
    });
  })
);

/** GET /api/admin/threads/by-user — every account that takes part in at least
 *  one conversation, with how many and when it was last active. Powers the
 *  "conversations grouped by user" view: pick a person here, then list their
 *  threads with `GET /threads?userId=`. Sorted by most recent activity. */
adminRouter.get(
  '/threads/by-user',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        query: z.string().optional(),
        page: z.coerce.number().int().min(0).optional(),
        pageSize: z.coerce.number().int().min(1).max(100).optional(),
      })
      .safeParse(req.query);
    if (!q.success) throw new ApiError(400, 'Filtres invalides', 'VALIDATION_FAILED');

    const search = q.data.query?.trim();
    const where: any = { threads: { some: {} } };
    if (search && search.length > 0) {
      const digits = search.replace(/\D/g, '');
      where.OR = [
        { fullName: { contains: search, mode: 'insensitive' } },
        { email: { contains: search, mode: 'insensitive' } },
        { phone: { contains: digits.length >= 3 ? digits : search } },
      ];
    }

    const users = await prisma.user.findMany({
      where,
      select: {
        id: true, fullName: true, email: true, phone: true,
        avatarUrl: true, avatarColor: true,
        isOwner: true, isAdmin: true, isSupport: true,
        _count: { select: { threads: true } },
        threads: {
          select: { thread: { select: { updatedAt: true } } },
          orderBy: { thread: { updatedAt: 'desc' } },
          take: 1,
        },
      },
    });

    // Ordering by a nested aggregate isn't expressible in Prisma, so sort and
    // page in memory — the participant set is small at admin scale.
    const rows = users
      .map(({ _count, threads, ...u }) => ({
        ...u,
        threadCount: _count.threads,
        lastActivity: threads[0]?.thread.updatedAt ?? null,
      }))
      .sort((a, b) => (b.lastActivity?.getTime() ?? 0) - (a.lastActivity?.getTime() ?? 0));

    const page = q.data.page ?? 0;
    const pageSize = q.data.pageSize ?? 30;
    res.json({
      total: rows.length,
      page,
      pageSize,
      items: rows.slice(page * pageSize, page * pageSize + pageSize),
    });
  })
);

/** GET /api/admin/threads/:id/messages — inspect a conversation. */
adminRouter.get(
  '/threads/:id/messages',
  asyncHandler(async (req, res) => {
    const messages = await prisma.message.findMany({
      where: { threadId: req.params.id },
      orderBy: { createdAt: 'asc' },
      take: 500,
      include: {
        sender: { select: { id: true, fullName: true, avatarColor: true } },
      },
    });
    res.json({ items: messages });
  })
);

/**
 * POST /api/admin/threads/:id/reply — answer a conversation as the listing's
 * owner. Restricted to Airbnb-imported listings: their "owner" is a Mobly-
 * seeded placeholder account nobody logs into, so a visitor who messages one
 * would otherwise never get an answer. Staff reply from this admin section and
 * the message reaches the visitor exactly as an owner reply — same socket
 * delivery, unread bump and push as a real owner's message.
 *
 * We deliberately refuse non-imported threads so this can never be used to
 * impersonate a real owner in their own conversation. The audit row records
 * which admin actually typed it.
 */
adminRouter.post(
  '/threads/:id/reply',
  requirePermission('user.notify'),
  asyncHandler(async (req, res) => {
    const { text } = z
      .object({ text: z.string().min(1).max(configSnapshot().limits.messageMaxLength) })
      .parse(req.body);

    const threadId = req.params.id;
    const thread = await prisma.thread.findUnique({
      where: { id: threadId },
      include: {
        listing: {
          select: {
            ownerId: true,
            tags: true,
            title: true,
            owner: { select: { fullName: true } },
          },
        },
      },
    });
    if (!thread) throw new ApiError(404, 'Conversation introuvable', 'NOT_FOUND');

    const ownerId = thread.listing?.ownerId;
    const imported = thread.listing?.tags?.includes('airbnb-import') ?? false;
    if (!ownerId || !imported) {
      throw new ApiError(
        403,
        "Cette conversation ne concerne pas une annonce importée.",
        'FORBIDDEN'
      );
    }

    const now = new Date();
    const [message] = await prisma.$transaction([
      prisma.message.create({
        data: { threadId, senderId: ownerId, kind: 'TEXT', text },
      }),
      prisma.thread.update({
        where: { id: threadId },
        data: { lastMessageAt: now, updatedAt: now },
      }),
      // The reply is unread for the visitor, not for the owner we posted as.
      prisma.threadParticipant.updateMany({
        where: { threadId, userId: { not: ownerId } },
        data: { unreadCount: { increment: 1 } },
      }),
      prisma.threadParticipant.updateMany({
        where: { threadId, userId: ownerId },
        data: { unreadCount: 0, lastReadAt: now },
      }),
    ]);

    const payload = serializeMessage(message);
    await broadcastMessage(threadId, { ...payload, senderId: ownerId });

    res.status(201).json({ message: payload });

    // Notify the visitor after the reply is saved and delivered; a push
    // failure must never fail the reply itself.
    const recipient = await prisma.threadParticipant.findFirst({
      where: { threadId, userId: { not: ownerId } },
      select: { userId: true },
    });
    if (recipient) {
      // Mirror a normal owner→visitor message notification exactly (same type,
      // sender-name title and payload) so the visitor's app treats it as an
      // ordinary reply and taps straight into the thread.
      void notifyUser({
        userId: recipient.userId,
        type: 'message',
        title: thread.listing?.owner?.fullName ?? 'Nouveau message',
        body: text.length > 120 ? text.slice(0, 117) + '…' : text,
        payload: {
          threadId,
          ...(thread.listing?.title ? { listingTitle: thread.listing.title } : {}),
        },
        threadId,
      }).catch((err) => console.error('[admin] imported reply push failed', err));
    }

    await audit(req, {
      action: 'thread.reply_as_owner',
      targetType: 'thread',
      targetId: threadId,
      after: { text: text.slice(0, 200), sentAs: ownerId },
    });
  })
);

// ═════════════════════════════════════════════════════════════
// Visits (across the whole marketplace)
// ═════════════════════════════════════════════════════════════

/** GET /api/admin/visits — cross-user visit inbox for supervision. */
adminRouter.get(
  '/visits',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        status: z.enum(['REQUESTED', 'CONFIRMED', 'CANCELLED', 'COMPLETED', 'NO_SHOW', 'all']).optional(),
        page: z.coerce.number().int().min(0).optional(),
        pageSize: z.coerce.number().int().min(1).max(100).optional(),
      })
      .safeParse(req.query);
    if (!q.success) throw new ApiError(400, 'Filtres invalides', 'VALIDATION_FAILED');
    const where: any = {};
    if (q.data.status && q.data.status !== 'all') where.status = q.data.status;
    const page = q.data.page ?? 0;
    const pageSize = q.data.pageSize ?? 30;

    const [total, items] = await Promise.all([
      prisma.visitRequest.count({ where }),
      prisma.visitRequest.findMany({
        where,
        orderBy: { scheduledAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
        include: {
          listing: { select: { id: true, title: true, city: true, imageName: true, coverUrl: true } },
          visitor: { select: { id: true, fullName: true, avatarColor: true } },
          owner:   { select: { id: true, fullName: true, avatarColor: true } },
        },
      }),
    ]);
    res.json({ total, page, pageSize, items });
  })
);

/** PATCH /api/admin/visits/:id — change status, reschedule or edit the note. */
adminRouter.patch(
  '/visits/:id',
  requirePermission('visit.update'),
  asyncHandler(async (req, res) => {
    const parsed = z
      .object({
        status: z.enum(['REQUESTED', 'CONFIRMED', 'CANCELLED', 'COMPLETED', 'NO_SHOW']).optional(),
        scheduledAt: z.coerce.date().optional(),
        note: z.string().max(1000).nullish(),
      })
      .safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');
    const patch = parsed.data;

    const sel = { id: true, status: true, scheduledAt: true, note: true, visitorId: true, ownerId: true, listingId: true } as const;
    const before = await prisma.visitRequest.findUnique({ where: { id: req.params.id }, select: sel });
    if (!before) throw new ApiError(404, 'Visite introuvable', 'NOT_FOUND');

    const after = await prisma.visitRequest.update({ where: { id: req.params.id }, data: patch, select: sel });
    await audit(req, { action: 'visit.edit', targetType: 'visit', targetId: after.id, ...diff(before, after, patch) });

    res.json({ visit: after });
  })
);

/** DELETE /api/admin/visits/:id. */
adminRouter.delete(
  '/visits/:id',
  requirePermission('visit.update'),
  asyncHandler(async (req, res) => {
    const before = await prisma.visitRequest.findUnique({ where: { id: req.params.id } });
    if (!before) throw new ApiError(404, 'Visite introuvable', 'NOT_FOUND');
    await prisma.visitRequest.delete({ where: { id: req.params.id } });
    await audit(req, { action: 'visit.delete', targetType: 'visit', targetId: before.id, before });
    res.json({ deleted: true });
  })
);

// ═════════════════════════════════════════════════════════════
// New-listing push — fired when an admin approves a listing
// (PENDING → ACTIVE). Notifies users in the same city who have
// a registered device, excluding the listing owner.
// ═════════════════════════════════════════════════════════════


// ═════════════════════════════════════════════════════════════
// Broadcast notifications — announcements, promos, incident
// alerts. Sent to every non-suspended user; a Notification row
// is created for each and a push is fanned out if they have a
// device token registered.
// ═════════════════════════════════════════════════════════════

const broadcastBody = z.object({
  type: z.string().default('ANNOUNCEMENT'),   // ANNOUNCEMENT | PROMO | ALERT
  title: z.string().min(1).max(120),
  body: z.string().min(1).max(500),
  payload: z.record(z.string()).optional(),
  /** Who receives it. Omitted = everyone, as before segments existed. */
  segment: z.enum(['all', 'owners', 'visitors']).default('all'),
  /** Optional city filter, matched case-insensitively against `User.city`. */
  city: z.string().trim().max(80).optional(),
});

/** Recipients of a broadcast: active accounts in the segment / city. */
function broadcastWhere(segment: 'all' | 'owners' | 'visitors', city?: string) {
  return {
    isActive: true,
    ...(segment === 'owners' ? { isOwner: true } : {}),
    ...(segment === 'visitors' ? { isOwner: false } : {}),
    ...(city ? { city: { equals: city, mode: 'insensitive' as const } } : {}),
  };
}

/** GET /api/admin/notifications/audience?segment=&city= — recipient count
 *  for a broadcast, so the operator sees the reach before sending. */
adminRouter.get(
  '/notifications/audience',
  asyncHandler(async (req, res) => {
    const { segment, city } = z
      .object({
        segment: z.enum(['all', 'owners', 'visitors']).default('all'),
        city: z.string().trim().max(80).optional(),
      })
      .parse(req.query);
    const count = await prisma.user.count({ where: broadcastWhere(segment, city || undefined) });
    res.json({ segment, city: city || null, count });
  })
);

/** GET /api/admin/notifications/cities — cities with at least one active
 *  user, most populated first, for the broadcast city picker. */
adminRouter.get(
  '/notifications/cities',
  asyncHandler(async (_req, res) => {
    const rows = await prisma.user.groupBy({
      by: ['city'],
      where: { isActive: true, city: { not: null } },
      _count: { _all: true },
      orderBy: { _count: { city: 'desc' } },
      take: 50,
    });
    res.json({ items: rows.filter((r) => r.city).map((r) => ({ city: r.city, users: r._count._all })) });
  })
);

/**
 * POST /api/admin/notifications/broadcast — send to every active user, or to
 * one segment (owners / visitors) and/or one city.
 *
 * Each send is recorded as a `ScheduledNotification` row that is already sent
 * (`sentAt` = now), which is what the history list reads back.
 */
adminRouter.post(
  '/notifications/broadcast',
  requirePermission('notification.broadcast'),
  asyncHandler(async (req, res) => {
    const b = broadcastBody.parse(req.body);
    const city = b.city || undefined;
    const users = await prisma.user.findMany({ where: broadcastWhere(b.segment, city), select: { id: true } });
    // Bulk insert notifications; push fan-out happens per user so an APNs
    // failure on one recipient doesn't block the others.
    await prisma.notification.createMany({
      data: users.map((u) => ({
        userId: u.id,
        type: b.type,
        title: b.title,
        body: b.body,
        payload: b.payload ?? {},
      })),
    });
    // Best-effort push. Import lazily so this route is still usable on
    // environments where APNs isn't configured.
    const { pushToUser } = await import('../services/push');
    await Promise.all(
      users.map((u) =>
        pushToUser(u.id, { title: b.title, body: b.body, data: b.payload }).catch(() => {})
      )
    );

    const now = new Date();
    await prisma.scheduledNotification
      .create({
        data: {
          segment: b.segment,
          city: city ?? null,
          type: b.type,
          title: b.title,
          body: b.body,
          payload: b.payload ?? {},
          scheduledAt: now,
          sentAt: now,
          sentCount: users.length,
          createdBy: req.userId!,
        },
      })
      .catch((err) => console.error('[admin] broadcast history write failed', err));
    await audit(req, {
      action: 'notification.broadcast',
      after: { segment: b.segment, city: city ?? null, title: b.title, sent: users.length },
    });
    res.json({ sent: users.length });
  })
);

/** GET /api/admin/notifications/history — broadcasts already sent, newest first. */
adminRouter.get(
  '/notifications/history',
  asyncHandler(async (req, res) => {
    const { page, pageSize } = z
      .object({
        page: z.coerce.number().int().min(0).default(0),
        pageSize: z.coerce.number().int().min(1).max(100).default(20),
      })
      .parse(req.query);
    const where = { sentAt: { not: null } };
    const [total, rows] = await Promise.all([
      prisma.scheduledNotification.count({ where }),
      prisma.scheduledNotification.findMany({
        where,
        orderBy: { sentAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
      }),
    ]);
    const authors = await prisma.user.findMany({
      where: { id: { in: [...new Set(rows.map((r) => r.createdBy))] } },
      select: { id: true, fullName: true },
    });
    const name = new Map(authors.map((a) => [a.id, a.fullName]));
    res.json({
      total, page, pageSize,
      items: rows.map((r) => ({ ...r, createdByName: name.get(r.createdBy) ?? null })),
    });
  })
);

/** POST /api/admin/notifications/user/:id — send to one user (for testing). */
adminRouter.post(
  '/notifications/user/:id',
  asyncHandler(async (req, res) => {
    const b = broadcastBody.parse(req.body);
    const u = await prisma.user.findUnique({ where: { id: req.params.id }, select: { id: true } });
    if (!u) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');
    const { notifyUser } = await import('../services/push');
    await notifyUser({
      userId: u.id,
      type: b.type,
      title: b.title,
      body: b.body,
      payload: b.payload,
    });
    res.json({ sent: 1 });
  })
);

// ═════════════════════════════════════════════════════════════
// Maintenance window
// ═════════════════════════════════════════════════════════════

/**
 * The dashboard sends a duration, not a wall-clock instant: "back in 2h30".
 * Resolving it to `endsAt` server-side means the countdown is anchored to the
 * server clock, so an admin whose laptop clock is off cannot publish a window
 * that ends in the past for everyone else.
 */
const maintenanceBody = z.object({
  enabled: z.boolean(),
  message: z.string().trim().max(300).nullish(),
  duration: z
    .object({
      days: z.number().int().min(0).max(365).default(0),
      hours: z.number().int().min(0).max(23).default(0),
      minutes: z.number().int().min(0).max(59).default(0),
      seconds: z.number().int().min(0).max(59).default(0),
    })
    .nullish(),
});

/** GET /api/admin/maintenance — current window. */
adminRouter.get(
  '/maintenance',
  asyncHandler(async (_req, res) => {
    const { getMaintenance, serializeMaintenance } = await import('../services/maintenance');
    res.json(serializeMaintenance(await getMaintenance()));
  })
);

/** PUT /api/admin/maintenance — open, adjust or lift the window. */
adminRouter.put(
  '/maintenance',
  asyncHandler(async (req, res) => {
    const b = maintenanceBody.parse(req.body);
    const { setMaintenance, serializeMaintenance } = await import('../services/maintenance');

    let endsAt: Date | null = null;
    if (b.enabled && b.duration) {
      const secs =
        b.duration.days * 86400 +
        b.duration.hours * 3600 +
        b.duration.minutes * 60 +
        b.duration.seconds;
      // A zero duration means "indefinite", not "ends immediately" — the app
      // then shows the maintenance screen with no countdown at all.
      if (secs > 0) endsAt = new Date(Date.now() + secs * 1000);
    }

    const state = await setMaintenance({
      enabled: b.enabled,
      message: b.message?.trim() ? b.message.trim() : null,
      endsAt,
      updatedBy: req.userId ?? null,
    });

    console.log(
      `[maintenance] ${b.enabled ? 'OPENED' : 'LIFTED'} by ${req.userId}` +
        (endsAt ? ` until ${endsAt.toISOString()}` : '')
    );
    res.json(serializeMaintenance(state));
  })
);
