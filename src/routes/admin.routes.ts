import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth, requireAdmin } from '../middleware/auth';
import { notifyUser, pushConfigured } from '../services/push';

export const adminRouter = Router();
adminRouter.use(requireAuth, requireAdmin);

// ═════════════════════════════════════════════════════════════
// Overview + analytics
// ═════════════════════════════════════════════════════════════

/** GET /api/admin/overview — top-line KPIs for the dashboard home. */
adminRouter.get(
  '/overview',
  asyncHandler(async (_req, res) => {
    const now = Date.now();
    const day = 24 * 60 * 60 * 1000;
    const since24h = new Date(now - day);
    const since30d = new Date(now - 30 * day);

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

    res.json({
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
  asyncHandler(async (_req, res) => {
    const now = Date.now();
    const day = 24 * 60 * 60 * 1000;

    const dayBuckets: { day: string; sessions: number; events: number }[] = [];
    for (let i = 29; i >= 0; i--) {
      const start = new Date(now - i * day);
      start.setHours(0, 0, 0, 0);
      const end = new Date(start.getTime() + day);
      const [sessions, events] = await Promise.all([
        prisma.appSession.count({ where: { startedAt: { gte: start, lt: end } } }),
        prisma.appEvent.count({ where: { createdAt: { gte: start, lt: end } } }),
      ]);
      dayBuckets.push({ day: start.toISOString().slice(0, 10), sessions, events });
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
} as const;

/** GET /api/admin/users — paginated, search, filter. */
adminRouter.get(
  '/users',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        query: z.string().optional(),
        role: z.enum(['all', 'owner', 'visitor', 'admin']).optional(),
        active: z.enum(['all', 'active', 'suspended']).optional(),
        page: z.coerce.number().int().min(0).optional(),
        pageSize: z.coerce.number().int().min(1).max(100).optional(),
      })
      .safeParse(req.query);
    if (!q.success) throw new ApiError(400, 'Filtres invalides', 'VALIDATION_FAILED');

    const search = q.data.query?.trim();
    const where: any = {};
    if (search && search.length > 0) {
      where.OR = [
        { fullName: { contains: search, mode: 'insensitive' } },
        { email: { contains: search, mode: 'insensitive' } },
        { phone: { contains: search } },
      ];
    }
    if (q.data.role === 'owner') where.isOwner = true;
    if (q.data.role === 'visitor') where.isOwner = false;
    if (q.data.role === 'admin') where.isAdmin = true;
    if (q.data.active === 'active') where.isActive = true;
    if (q.data.active === 'suspended') where.isActive = false;

    const page = q.data.page ?? 0;
    const pageSize = q.data.pageSize ?? 20;

    const [total, items] = await Promise.all([
      prisma.user.count({ where }),
      prisma.user.findMany({
        where,
        select: userSummarySelect,
        orderBy: { createdAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
      }),
    ]);

    res.json({ total, page, pageSize, items });
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

/** DELETE /api/admin/users/:id — permanent removal (Prisma cascades listings, messages…). */
adminRouter.delete(
  '/users/:id',
  asyncHandler(async (req, res) => {
    if (req.params.id === req.userId!) {
      throw new ApiError(400, 'Impossible de supprimer votre propre compte ici', 'VALIDATION_FAILED');
    }
    await prisma.user.delete({ where: { id: req.params.id } }).catch(() => {
      throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');
    });
    res.json({ deleted: true });
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
    if (q.data.category && q.data.category !== 'all') where.category = q.data.category;
    if (q.data.city && q.data.city !== 'all') where.city = q.data.city;

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

/** PATCH /api/admin/listings/:id — moderation flags + status. */
adminRouter.patch(
  '/listings/:id',
  asyncHandler(async (req, res) => {
    const body = z
      .object({
        status: z.enum(['DRAFT', 'PENDING', 'ACTIVE', 'BOOSTED', 'PAUSED', 'REJECTED', 'ARCHIVED']).optional(),
        available: z.boolean().optional(),
        verified: z.boolean().optional(),
      })
      .safeParse(req.body);
    if (!body.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');

    const prev = body.data.status
      ? await prisma.listing.findUnique({ where: { id: req.params.id }, select: { status: true, ownerId: true } })
      : null;

    const listing = await prisma.listing.update({
      where: { id: req.params.id },
      data: body.data,
      select: listingSummarySelect,
    });

    // When a listing goes ACTIVE for the first time, notify users in the same city.
    if (body.data.status === 'ACTIVE' && prev && prev.status !== 'ACTIVE') {
      notifyNewListing(listing as any, prev.ownerId).catch(() => {});
    }

    res.json({ listing });
  })
);

/** DELETE /api/admin/listings/:id. */
adminRouter.delete(
  '/listings/:id',
  asyncHandler(async (req, res) => {
    await prisma.listing.delete({ where: { id: req.params.id } }).catch(() => {
      throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
    });
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
        page: z.coerce.number().int().min(0).optional(),
        pageSize: z.coerce.number().int().min(1).max(100).optional(),
      })
      .safeParse(req.query);
    if (!q.success) throw new ApiError(400, 'Filtres invalides', 'VALIDATION_FAILED');

    const search = q.data.query?.trim();
    const where: any = {};
    if (search && search.length > 0) {
      where.OR = [
        { listing: { title: { contains: search, mode: 'insensitive' } } },
        {
          participants: {
            some: {
              user: {
                OR: [
                  { fullName: { contains: search, mode: 'insensitive' } },
                  { email: { contains: search, mode: 'insensitive' } },
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
          listing: { select: { id: true, title: true, imageName: true, coverUrl: true } },
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
      items: items.map((t) => ({
        id: t.id,
        listing: t.listing,
        participants: t.participants.map((p) => p.user),
        messageCount: t._count.messages,
        lastMessage: t.messages[0] ?? null,
        updatedAt: t.updatedAt,
      })),
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

// ═════════════════════════════════════════════════════════════
// New-listing push — fired when an admin approves a listing
// (PENDING → ACTIVE). Notifies users in the same city who have
// a registered device, excluding the listing owner.
// ═════════════════════════════════════════════════════════════

async function notifyNewListing(
  listing: { id: string; title: string; city: string; neighborhood?: string | null; priceFcfa: number },
  ownerId: string,
) {
  if (!pushConfigured()) return;

  const price = new Intl.NumberFormat('fr-FR').format(listing.priceFcfa) + ' FCFA';
  const where = listing.neighborhood
    ? `${listing.neighborhood}, ${listing.city}`
    : listing.city;

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
});

/** POST /api/admin/notifications/broadcast — send to every user. */
adminRouter.post(
  '/notifications/broadcast',
  asyncHandler(async (req, res) => {
    const b = broadcastBody.parse(req.body);
    const users = await prisma.user.findMany({ select: { id: true } });
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
    res.json({ sent: users.length });
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
