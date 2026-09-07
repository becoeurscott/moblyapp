import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth, requireOwner } from '../middleware/auth';
import { featureGate, restrictionGate } from '../middleware/gates';
import { configSnapshot } from '../services/config';
import { serializeListing } from '../lib/serialize';
import { cacheBust } from '../lib/cache';

export const boostRouter = Router();

/**
 * Boost plans now live in the remote configuration, so prices can be changed
 * (or a promotion run) from the dashboard without a deploy. `configSnapshot()`
 * is the same list the app renders in its BoostSheet.
 */
export function boostPlans() {
  return configSnapshot().boost.plans;
}

/** GET /api/boost/plans */
boostRouter.get('/plans', (_req, res) => {
  const plans = boostPlans();
  // Guard against a configuration with no plans — `Math.max()` of an empty
  // list is -Infinity, which would render every price as NaN in the app.
  const baseline = plans.length
    ? Math.max(...plans.map((p) => p.priceFcfa / p.days))
    : 0;
  res.json({
    plans: plans.map((p) => {
      const perDay = Math.round(p.priceFcfa / p.days);
      return {
        days: p.days,
        priceFcfa: p.priceFcfa,
        tagline: p.label,
        popular: p.popular,
        perDay,
        savingsPct: baseline ? Math.round((1 - perDay / baseline) * 100) : 0,
      };
    }),
  });
});

/**
 * POST /api/boost/:listingId — activate a boost.
 * NOTE: payment (Mobile Money) must be confirmed by your payment provider's
 * webhook BEFORE calling this in production. This endpoint only records the
 * boost and elevates the listing; it does not charge money.
 */
boostRouter.post(
  '/:listingId',
  requireAuth,
  requireOwner,
  featureGate('boost.enabled'),
  restrictionGate('BOOST'),
  asyncHandler(async (req, res) => {
    const { days } = z.object({ days: z.number().int().positive() }).parse(req.body);
    const plan = boostPlans().find((p) => p.days === days);
    if (!plan) throw new ApiError(400, 'Forfait de boost invalide', 'VALIDATION_FAILED');

    const listing = await prisma.listing.findUnique({
      where: { id: req.params.listingId },
      select: { ownerId: true, available: true },
    });
    if (!listing) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
    if (listing.ownerId !== req.userId!) throw new ApiError(403, 'Non autorisé', 'FORBIDDEN');
    if (!listing.available)
      throw new ApiError(400, 'Une annonce indisponible ne peut pas être boostée', 'CONFLICT');

    const expiresAt = new Date(Date.now() + plan.days * 24 * 60 * 60 * 1000);
    await prisma.boost.create({
      data: { listingId: req.params.listingId, days: plan.days, priceFcfa: plan.priceFcfa, expiresAt },
    });
    const updated = await prisma.listing.update({
      where: { id: req.params.listingId },
      data: { status: 'BOOSTED', boostDaysLeft: plan.days, boostExpiresAt: expiresAt },
      include: { owner: { select: { id: true, fullName: true, verified: true, rating: true, avatarUrl: true } } },
    });
    cacheBust('listings:'); // boosting changes list ordering
    res.json({ listing: serializeListing(updated) });
  })
);
