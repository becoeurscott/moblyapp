import { Router } from 'express';
import rateLimit from 'express-rate-limit';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth } from '../middleware/auth';
import { createSession, retrieveDecision, mapStatus, verifyWebhook } from '../services/didit';
import type { IdentityStatus } from '../services/didit';

export const verificationRouter = Router();

/**
 * Identity verification (Didit hosted KYC).
 *
 *   POST /verification/session  → start a check, returns a one-shot hosted URL
 *   GET  /verification/me       → current status for the signed-in user
 *   POST /verification/webhook  → Didit callback (signed, unauthenticated)
 */

/** A session costs money per run, so cap how fast one account can burn them. */
const sessionLimiter = rateLimit({
  windowMs: 60 * 60 * 1000,
  limit: 5,
  standardHeaders: true,
  legacyHeaders: false,
  // Always keyed by user: `requireAuth` runs first, so userId is set. Keying on
  // req.ip instead would need the IPv6-safe helper and would punish everyone
  // behind one NAT.
  keyGenerator: (req) => req.userId ?? 'anon',
  message: { error: 'Trop de tentatives. Réessayez plus tard.', code: 'RATE_LIMITED' },
});

/** Statuses that mean "a check is already running" — don't start a second one. */
const OPEN_STATUSES: IdentityStatus[] = ['PENDING', 'IN_REVIEW'];

/**
 * POST /api/verification/session
 * Starts a check and returns the hosted URL for the app to open.
 */
verificationRouter.post(
  '/session',
  requireAuth,
  sessionLimiter,
  asyncHandler(async (req, res) => {
    const userId = req.userId!;

    const user = await prisma.user.findUnique({
      where: { id: userId },
      select: { identityVerified: true },
    });
    if (!user) throw new ApiError(404, 'Compte introuvable', 'NOT_FOUND');
    if (user.identityVerified) {
      throw new ApiError(409, 'Votre identité est déjà vérifiée', 'CONFLICT');
    }

    // Hand back an in-flight session rather than minting a new one: the user
    // has most likely just closed the sheet, and every session is billable.
    const open = await prisma.identityCheck.findFirst({
      where: { userId, status: { in: OPEN_STATUSES }, hostedUrl: { not: null } },
      orderBy: { createdAt: 'desc' },
    });
    if (open && Date.now() - open.createdAt.getTime() < 30 * 60 * 1000) {
      // Confirm with the provider before reusing — the row may be stale if a
      // webhook was missed, and we must not send the user back into a flow
      // that already resolved.
      const { status } = await retrieveDecision(open.providerSessionId);
      if (OPEN_STATUSES.includes(mapStatus(status))) {
        return res.json({ checkId: open.id, url: open.hostedUrl!, status: open.status });
      }
    }

    const session = await createSession(userId);
    const check = await prisma.identityCheck.create({
      data: { userId, providerSessionId: session.sessionId, hostedUrl: session.url },
    });

    res.status(201).json({ checkId: check.id, url: session.url, status: 'PENDING' });
  })
);

/**
 * GET /api/verification/me — status for the signed-in user.
 *
 * The app polls this when it comes back from the hosted flow, since the webhook
 * may not have landed yet. If the local row is still open we ask the provider
 * directly, so a dropped webhook can't strand a user on "pending" forever.
 */
verificationRouter.get(
  '/me',
  requireAuth,
  asyncHandler(async (req, res) => {
    const userId = req.userId!;
    const user = await prisma.user.findUnique({
      where: { id: userId },
      select: { identityVerified: true, verifiedAt: true },
    });
    if (!user) throw new ApiError(404, 'Compte introuvable', 'NOT_FOUND');

    let check = await prisma.identityCheck.findFirst({
      where: { userId },
      orderBy: { createdAt: 'desc' },
    });

    if (check && OPEN_STATUSES.includes(check.status as IdentityStatus)) {
      try {
        const { status } = await retrieveDecision(check.providerSessionId);
        const mapped = mapStatus(status);
        if (mapped !== check.status) {
          check = await applyDecision(check.providerSessionId, mapped, status, null);
        }
      } catch (err) {
        // A provider hiccup must not break the profile screen — fall through
        // and report the status we already have.
        console.error('[verification] poll failed', err);
      }
    }

    res.json({
      identityVerified: user.identityVerified,
      verifiedAt: user.verifiedAt,
      status: check?.status ?? 'NONE',
      reason: check?.reason ?? null,
      updatedAt: check?.updatedAt ?? null,
    });
  })
);

/**
 * POST /api/verification/webhook — Didit's callback.
 *
 * Deliberately unauthenticated: it is called by Didit, not by a user. The HMAC
 * signature is the only thing standing between this endpoint and a forged
 * "Approved", so an unverified payload is dropped before it can touch the DB.
 */
verificationRouter.post(
  '/webhook',
  asyncHandler(async (req, res) => {
    const body = (req.body ?? {}) as Record<string, unknown>;

    const ok = verifyWebhook(body, {
      signatureV2: req.get('x-signature-v2') ?? undefined,
      signatureSimple: req.get('x-signature-simple') ?? undefined,
      timestamp: req.get('x-timestamp') ?? undefined,
    });
    if (!ok) {
      console.warn('[verification] rejected webhook with bad signature');
      throw new ApiError(401, 'Signature invalide', 'UNAUTHENTICATED');
    }

    const sessionId = typeof body.session_id === 'string' ? body.session_id : null;
    const providerStatus = typeof body.status === 'string' ? body.status : null;
    if (!sessionId || !providerStatus) {
      throw new ApiError(400, 'Payload invalide', 'VALIDATION_FAILED');
    }

    // Apply before acking. The work is two indexed writes, and `applyDecision`
    // is idempotent, so letting a failure surface as a 5xx buys us Didit's
    // retries — acking first would silently drop an approval on a DB blip.
    try {
      const reason = extractReason(body);
      await applyDecision(sessionId, mapStatus(providerStatus), providerStatus, reason);
    } catch (err) {
      // A session we don't know (another environment sharing the Didit account)
      // is nothing to retry — ack it and move on.
      if ((err as { code?: string }).code === 'P2025') {
        console.warn('[verification] webhook for unknown session', sessionId);
        return res.json({ ok: true, ignored: true });
      }
      throw err;
    }

    res.json({ ok: true });
  })
);

/** Pull a human-readable decline reason out of the `decision` object, if present. */
function extractReason(body: Record<string, unknown>): string | null {
  const decision = body.decision as Record<string, unknown> | undefined;
  if (!decision) return null;
  const direct = decision.reason ?? decision.comment ?? decision.warning;
  if (typeof direct === 'string' && direct.trim()) return direct.trim().slice(0, 500);

  const idChecks = decision.id_verifications;
  if (Array.isArray(idChecks)) {
    for (const entry of idChecks) {
      const r = (entry as Record<string, unknown>)?.warnings ?? (entry as Record<string, unknown>)?.reason;
      if (typeof r === 'string' && r.trim()) return r.trim().slice(0, 500);
    }
  }
  return null;
}

/**
 * Record a decision and, on approval, award the badge.
 *
 * `identityVerified` is only ever set from here, and only forward: a later
 * webhook for an old session must not strip a badge the user already earned.
 */
async function applyDecision(
  providerSessionId: string,
  status: IdentityStatus,
  providerStatus: string,
  reason: string | null
) {
  const decided = status === 'APPROVED' || status === 'DECLINED' || status === 'ABANDONED';

  const check = await prisma.identityCheck.update({
    where: { providerSessionId },
    data: {
      status,
      providerStatus,
      reason: status === 'DECLINED' ? reason : null,
      decidedAt: decided ? new Date() : null,
    },
  });

  if (status === 'APPROVED') {
    await prisma.user.update({
      where: { id: check.userId },
      data: { identityVerified: true, verifiedAt: new Date() },
    });
  }

  return check;
}
