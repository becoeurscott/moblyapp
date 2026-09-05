import { Router, Request, Response, NextFunction } from 'express';
import { prisma } from '../lib/prisma';
import { asyncHandler } from '../lib/http';
import { env } from '../config/env';
import { notifyUser, pushConfigured } from '../services/push';

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

// ═════════════════════════════════════════════════════════════
// Re-engagement notifications
//
// Called on a schedule (e.g. daily via Render cron or external
// scheduler). Finds users who haven't opened the app in a
// while and sends them a push to bring them back.
//
// Three tiers:
//   • 3 days inactive  → gentle nudge
//   • 7 days inactive  → highlight new listings
//   • 14 days inactive → "on vous attend" last-chance
//
// Each tier is sent at most once per user (tracked via the
// Notification table — if a notification of that type already
// exists for the user, skip).
// ═════════════════════════════════════════════════════════════

interface ReengagementTier {
  key: string;
  daysMin: number;
  daysMax: number;
  title: string;
  body: string;
}

const TIERS: ReengagementTier[] = [
  {
    key: 'reengage_3d',
    daysMin: 3,
    daysMax: 6,
    title: 'Vous nous manquez ! 🏠',
    body: 'De nouveaux espaces ont été ajoutés près de chez vous. Venez les découvrir !',
  },
  {
    key: 'reengage_7d',
    daysMin: 7,
    daysMax: 13,
    title: 'Des espaces vous attendent 🔑',
    body: 'Plusieurs propriétaires ont publié de nouvelles annonces cette semaine. Ne ratez pas les meilleures offres !',
  },
  {
    key: 'reengage_14d',
    daysMin: 14,
    daysMax: 60,
    title: 'On vous attend sur Mobly ! 💙',
    body: 'Ça fait un moment ! Votre prochain espace idéal est peut-être déjà en ligne. Un coup d\'œil ?',
  },
];

/** POST /api/cron/reengage — send re-engagement pushes to inactive users. */
cronRouter.post(
  '/reengage',
  asyncHandler(async (_req, res) => {
    if (!pushConfigured()) {
      res.json({ skipped: true, reason: 'APNs not configured' });
      return;
    }

    const now = Date.now();
    const DAY = 24 * 60 * 60 * 1000;
    let totalSent = 0;

    for (const tier of TIERS) {
      const from = new Date(now - tier.daysMax * DAY);
      const to = new Date(now - tier.daysMin * DAY);

      // Find users with a device who were last seen in this window
      // and haven't already received this tier's notification.
      const candidates = await prisma.user.findMany({
        where: {
          devices: {
            some: {
              pushToken: { not: null },
              lastSeenAt: { gte: from, lte: to },
            },
          },
          notifications: {
            none: { type: tier.key },
          },
        },
        select: { id: true },
        take: 500,
      });

      for (const user of candidates) {
        try {
          await notifyUser({
            userId: user.id,
            type: tier.key,
            title: tier.title,
            body: tier.body,
          });
          totalSent++;
        } catch {
          // Best-effort — a single failure shouldn't abort the batch.
        }
      }
    }

    res.json({ sent: totalSent });
  })
);

/** GET /api/cron/health — verify the cron secret works. */
cronRouter.get('/health', (_req, res) => {
  res.json({ ok: true, pushConfigured: pushConfigured() });
});
