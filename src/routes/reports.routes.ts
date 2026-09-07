import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth } from '../middleware/auth';
import { writeLimiter } from '../middleware/security';
import { featureGate, restrictionGate } from '../middleware/gates';
import { configSnapshot } from '../services/config';
import { cacheBust } from '../lib/cache';

/**
 * User-filed reports.
 *
 * The `Report` table and the whole admin moderation queue existed already, but
 * nothing could write to it — the app's "Signaler" button only logged an
 * analytics event. The moderation queue was therefore permanently empty. This
 * is the missing ingestion path.
 */
export const reportsRouter = Router();

const body = z.object({
  target: z.enum(['LISTING', 'USER', 'MESSAGE', 'REVIEW']),
  targetId: z.string().min(1).max(64),
  reason: z.string().min(3).max(120),
  details: z.string().max(1000).optional(),
});

reportsRouter.post(
  '/',
  requireAuth,
  featureGate('reports.file'),
  restrictionGate('REPORT_FILE'),
  writeLimiter,
  asyncHandler(async (req, res) => {
    const input = body.parse(req.body);
    const reporterId = req.userId!;

    // Daily cap. Report spam is itself a harassment vector — a user can bury a
    // competitor's listing under a hundred reports otherwise.
    const since = new Date(Date.now() - 24 * 60 * 60 * 1000);
    const todayCount = await prisma.report.count({
      where: { reporterId, createdAt: { gte: since } },
    });
    if (todayCount >= configSnapshot().limits.reportsPerDay) {
      throw new ApiError(
        429,
        'Vous avez atteint la limite de signalements pour aujourd’hui.',
        'RATE_LIMITED'
      );
    }

    // One open report per person per target. Re-reporting the same thing adds
    // nothing for a moderator and inflates the auto-pause counter below.
    const existing = await prisma.report.findFirst({
      where: {
        reporterId,
        target: input.target,
        targetId: input.targetId,
        status: { in: ['OPEN', 'REVIEWING'] },
      },
      select: { id: true },
    });
    if (existing) {
      res.status(200).json({ report: { id: existing.id }, duplicate: true });
      return;
    }

    const report = await prisma.report.create({
      data: {
        reporterId,
        target: input.target,
        targetId: input.targetId,
        reason: input.reason,
        details: input.details ?? null,
      },
      select: { id: true, status: true, createdAt: true },
    });

    // Optional automatic containment: once a listing passes the configured
    // number of distinct open reports, pause it pending review rather than
    // leaving it live for however long the moderation queue takes.
    const threshold = configSnapshot().moderation.autoPauseListingAfterReports;
    if (threshold > 0 && input.target === 'LISTING') {
      const open = await prisma.report.count({
        where: { target: 'LISTING', targetId: input.targetId, status: { in: ['OPEN', 'REVIEWING'] } },
      });
      if (open >= threshold) {
        await prisma.listing
          .update({ where: { id: input.targetId }, data: { status: 'PAUSED' } })
          .then(() => cacheBust('listings:'))
          .catch(() => undefined); // listing already gone — nothing to pause
      }
    }

    res.status(201).json({ report });
  })
);
