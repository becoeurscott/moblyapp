import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { optionalAuth, requireAuth } from '../middleware/auth';
import { writeLimiter } from '../middleware/security';

export const analyticsRouter = Router();

/**
 * POST /api/sessions/start — mint a session for this app-open.
 *
 * Anonymous when the caller has no Bearer token; the same session id is later
 * `attach`ed to a userId at sign-in so the sign-up funnel is preserved.
 */
analyticsRouter.post(
  '/sessions/start',
  optionalAuth,
  writeLimiter,
  asyncHandler(async (req, res) => {
    const parsed = z
      .object({
        deviceId: z.string().min(4).max(128),
        appVersion: z.string().max(32).optional(),
        os: z.string().max(48).optional(),
        city: z.string().max(64).optional(),
      })
      .safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');

    const s = await prisma.appSession.create({
      data: {
        userId: req.userId ?? null,
        deviceId: parsed.data.deviceId,
        appVersion: parsed.data.appVersion,
        os: parsed.data.os,
        city: parsed.data.city,
      },
      select: { id: true, startedAt: true },
    });
    res.status(201).json({ sessionId: s.id, startedAt: s.startedAt });
  })
);

/**
 * POST /api/sessions/attach — link an anonymous session to the caller.
 *
 * Called from the client the moment sign-in completes. Only fills userId when
 * still null, so a re-run doesn't overwrite an already-attached session.
 */
analyticsRouter.post(
  '/sessions/attach',
  requireAuth,
  writeLimiter,
  asyncHandler(async (req, res) => {
    const parsed = z.object({ sessionId: z.string().min(4) }).safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');
    const updated = await prisma.appSession.updateMany({
      where: { id: parsed.data.sessionId, userId: null },
      data: { userId: req.userId!, lastActiveAt: new Date() },
    });
    res.json({ attached: updated.count === 1 });
  })
);

/** POST /api/sessions/heartbeat — bump lastActiveAt. */
analyticsRouter.post(
  '/sessions/heartbeat',
  optionalAuth,
  asyncHandler(async (req, res) => {
    const parsed = z.object({ sessionId: z.string().min(4) }).safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');
    await prisma.appSession.updateMany({
      where: { id: parsed.data.sessionId },
      data: { lastActiveAt: new Date() },
    });
    res.json({ ok: true });
  })
);

/** POST /api/sessions/end — close a session when the app backgrounds. */
analyticsRouter.post(
  '/sessions/end',
  optionalAuth,
  asyncHandler(async (req, res) => {
    const parsed = z.object({ sessionId: z.string().min(4) }).safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');
    await prisma.appSession.updateMany({
      where: { id: parsed.data.sessionId, endedAt: null },
      data: { endedAt: new Date(), lastActiveAt: new Date() },
    });
    res.json({ ok: true });
  })
);

/**
 * POST /api/events — batch of typed events.
 *
 * Payload is small JSON — no free-form text, no PII beyond what's already on
 * the record. Rejects batches over 100 events per call.
 */
analyticsRouter.post(
  '/events',
  optionalAuth,
  asyncHandler(async (req, res) => {
    const parsed = z
      .object({
        sessionId: z.string().min(4),
        events: z
          .array(
            z.object({
              name: z.string().min(1).max(60),
              payload: z.record(z.any()).optional(),
              at: z.string().datetime().optional(),
            })
          )
          .min(1)
          .max(100),
      })
      .safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');

    // Confirm the session belongs to this device (auth optional). If a userId
    // is on the session, and a signed-in caller mismatches, reject — someone
    // is either lying about their session or a token was stolen.
    const session = await prisma.appSession.findUnique({
      where: { id: parsed.data.sessionId },
      select: { userId: true },
    });
    if (!session) throw new ApiError(404, 'Session introuvable', 'NOT_FOUND');
    if (session.userId && req.userId && session.userId !== req.userId) {
      throw new ApiError(403, 'Session non autorisée', 'FORBIDDEN');
    }

    await prisma.appEvent.createMany({
      data: parsed.data.events.map((e) => ({
        sessionId: parsed.data.sessionId,
        userId: session.userId ?? req.userId ?? null,
        name: e.name,
        payload: (e.payload ?? {}) as any,
        createdAt: e.at ? new Date(e.at) : undefined,
      })),
    });

    // Cheap heartbeat side-effect — no extra round-trip needed from the client.
    prisma.appSession
      .updateMany({
        where: { id: parsed.data.sessionId },
        data: { lastActiveAt: new Date() },
      })
      .catch(() => {});

    res.json({ ok: true, count: parsed.data.events.length });
  })
);

/** GET /api/me/sessions — the caller's own sessions, most recent first. */
analyticsRouter.get(
  '/me/sessions',
  requireAuth,
  asyncHandler(async (req, res) => {
    const items = await prisma.appSession.findMany({
      where: { userId: req.userId! },
      orderBy: { startedAt: 'desc' },
      take: 50,
      select: {
        id: true,
        deviceId: true,
        startedAt: true,
        endedAt: true,
        lastActiveAt: true,
        appVersion: true,
        os: true,
        city: true,
      },
    });
    res.json({ items });
  })
);
