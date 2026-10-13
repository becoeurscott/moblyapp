import { Router, Request, Response, NextFunction } from 'express';
import { prisma } from '../lib/prisma';
import { asyncHandler } from '../lib/http';
import { env } from '../config/env';
import { notifyUser, pushConfigured } from '../services/push';
import { getConfig, isFlagEnabled } from '../services/config';

export const cronRouter = Router();

function requireCronSecret(req: Request, res: Response, next: NextFunction) {
  const secret = req.headers['x-cron-secret'] ?? req.query.secret;
  if (!env.cronSecret || secret !== env.cronSecret) {
    res.status(401).json({ error: 'Unauthorized' });
    return;
  }
  next();
}

cronRouter.use(requireCronSecret);

// One reminder per tier in each inactive period, with a minimum three-day gap.
// The external scheduler runs daily; dryRun inspects eligibility without sending.
cronRouter.post(
  '/reengage',
  asyncHandler(async (req, res) => {
    if (!pushConfigured() || !isFlagEnabled('notifications.push', await getConfig())) {
      res.json({ skipped: true, reason: 'Push notifications unavailable or disabled' });
      return;
    }
    const DAY = 86_400_000;
    const now = new Date();
    const cutoff = new Date(now.getTime() - 3 * DAY);
    const users = await prisma.user.findMany({
      where: {
        isActive: true,
        devices: { some: { pushToken: { not: null } }, none: { lastSeenAt: { gt: cutoff } } },
        sessions: { none: { lastActiveAt: { gt: cutoff } } },
        OR: [{ lastSeenAt: null }, { lastSeenAt: { lte: cutoff } }],
      },
      select: {
        id: true, city: true, locale: true, createdAt: true, lastSeenAt: true,
        devices: { select: { lastSeenAt: true } },
        sessions: { orderBy: { lastActiveAt: 'desc' }, take: 1, select: { lastActiveAt: true } },
      },
      orderBy: { id: 'asc' },
    });
    let eligible = 0;
    let queued = 0;
    const dryRun = req.body?.dryRun === true;
    for (const user of users) {
      const lastActive = new Date(Math.max(
        user.createdAt.getTime(), user.lastSeenAt?.getTime() ?? 0,
        ...user.devices.map(d => d.lastSeenAt.getTime()),
        ...user.sessions.map(s => s.lastActiveAt.getTime()),
      ));
      const days = (now.getTime() - lastActive.getTime()) / DAY;
      if (days < 3 || days > 60) continue;
      const type = days >= 14 ? 'reengage_14d' : days >= 7 ? 'reengage_7d' : 'reengage_3d';
      const previous = await prisma.notification.findFirst({
        where: { userId: user.id, type: { in: ['reengage_3d', 'reengage_7d', 'reengage_14d'] }, createdAt: { gte: lastActive } },
        orderBy: { createdAt: 'desc' },
      });
      if (previous && (previous.type === type || now.getTime() - previous.createdAt.getTime() < 3 * DAY)) continue;
      eligible++;
      if (dryRun) continue;
      const localListings = user.city ? await prisma.listing.count({
        where: { city: { equals: user.city, mode: 'insensitive' }, status: { in: ['ACTIVE', 'BOOSTED'] }, publishedAt: { gt: lastActive }, ownerId: { not: user.id } },
      }) : 0;
      const english = user.locale.startsWith('en');
      const body = localListings > 0
        ? (english ? `New properties in ${user.city} are waiting for you. Explore them on Mobly.` : `De nouvelles annonces à ${user.city} vous attendent. Découvrez-les sur Mobly.`)
        : (english ? 'Continue your property search on Mobly. Your next space may be waiting for you.' : 'Reprenez votre recherche sur Mobly. Votre prochain espace vous attend peut-être.');
      try {
        await notifyUser({ userId: user.id, type, title: english ? 'Find your next space 🏠' : 'Trouvez votre prochain espace 🏠', body, payload: { screen: 'home', type } });
        queued++;
      } catch (err) {
        console.error('[reengage] notification failed', { userId: user.id, error: String(err) });
      }
    }
    res.json({ dryRun, eligible, queued });
  })
);

/** GET /api/cron/health — verify the cron secret works. */
cronRouter.get('/health', (_req, res) => {
  res.json({ ok: true, pushConfigured: pushConfigured() });
});
