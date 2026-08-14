import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler } from '../lib/http';
import { requireAuth } from '../middleware/auth';

export const devicesRouter = Router();

/**
 * POST /api/devices — register (or refresh) this device's push token.
 *
 * Upserted on `(userId, pushToken)`: iOS reissues the token on reinstall and
 * occasionally on OS upgrade, and the app re-registers on every launch, so
 * inserting blindly would accumulate a row per launch.
 */
devicesRouter.post(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const body = z
      .object({
        pushToken: z.string().min(32).max(200),
        platform: z.enum(['ios', 'android']).default('ios'),
        appVersion: z.string().max(20).optional(),
        locale: z.string().max(10).optional(),
      })
      .parse(req.body);

    // The same physical device can change hands between accounts (a shared
    // phone, or sign-out then sign-in). Detach the token from anyone else so
    // the previous user stops receiving this device's notifications.
    await prisma.device.deleteMany({
      where: { pushToken: body.pushToken, userId: { not: req.userId! } },
    });

    const device = await prisma.device.upsert({
      where: { userId_pushToken: { userId: req.userId!, pushToken: body.pushToken } },
      create: {
        userId: req.userId!,
        pushToken: body.pushToken,
        platform: body.platform,
        appVersion: body.appVersion,
        locale: body.locale,
      },
      update: {
        lastSeenAt: new Date(),
        appVersion: body.appVersion,
        locale: body.locale,
      },
    });
    res.json({ registered: true, id: device.id });
  })
);

/** DELETE /api/devices — stop notifications for this device (sign-out). */
devicesRouter.delete(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { pushToken } = z.object({ pushToken: z.string() }).parse(req.body);
    await prisma.device.deleteMany({ where: { userId: req.userId!, pushToken } });
    res.status(204).end();
  })
);
