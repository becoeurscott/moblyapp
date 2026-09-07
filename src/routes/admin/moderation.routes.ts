import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma';
import { asyncHandler, ApiError } from '../../lib/http';
import { requirePermission } from '../../middleware/auth';
import { audit } from '../../lib/audit';
import { emitToUsers, threadParticipantIds } from '../../realtime/hub';
import { cacheBust } from '../../lib/cache';
import { grantRestriction } from '../../services/restrictions';
import { notifyUser } from '../../services/push';

/** Content moderation: messages, threads, reviews, listings, reports. */
export const adminModerationRouter = Router();

// ─────────────────────────────────────────────────────────────
// Messages and threads
// ─────────────────────────────────────────────────────────────

/**
 * DELETE /admin/moderation/messages/:id — soft-delete one message.
 *
 * Soft, because the row is the evidence for the moderation decision: the
 * transcript endpoint already filters `deletedAt`, so the message disappears
 * for users while remaining available to whoever has to justify the call.
 */
adminModerationRouter.delete(
  '/messages/:id',
  requirePermission('message.delete'),
  asyncHandler(async (req, res) => {
    const { reason } = z.object({ reason: z.string().max(300).optional() }).parse(req.body ?? {});
    const message = await prisma.message.findUnique({
      where: { id: req.params.id },
      select: { id: true, threadId: true, deletedAt: true },
    });
    if (!message) throw new ApiError(404, 'Message introuvable', 'NOT_FOUND');
    if (message.deletedAt) return res.json({ ok: true, alreadyDeleted: true });

    await prisma.message.update({
      where: { id: message.id },
      data: { deletedAt: new Date(), deletedBy: req.userId!, deleteReason: reason ?? null },
    });

    // Tell the participants so the bubble disappears from open conversations
    // rather than lingering until the app is relaunched.
    const ids = await threadParticipantIds(message.threadId);
    emitToUsers(ids, { type: 'message:deleted', threadId: message.threadId, messageId: message.id });

    await audit(req, {
      action: 'message.delete', targetType: 'message', targetId: message.id,
      after: { reason: reason ?? null },
    });
    res.json({ ok: true });
  })
);

/** POST /admin/moderation/threads/:id/freeze — stop new messages in a thread. */
adminModerationRouter.post(
  '/threads/:id/freeze',
  requirePermission('thread.moderate'),
  asyncHandler(async (req, res) => {
    const { frozen, reason } = z
      .object({ frozen: z.boolean(), reason: z.string().max(300).optional() })
      .parse(req.body);

    const thread = await prisma.thread.update({
      where: { id: req.params.id },
      data: {
        frozenAt: frozen ? new Date() : null,
        frozenReason: frozen ? (reason ?? null) : null,
      },
      select: { id: true, frozenAt: true, frozenReason: true },
    });

    const ids = await threadParticipantIds(thread.id);
    emitToUsers(ids, {
      type: 'thread:frozen',
      threadId: thread.id,
      frozen,
      reason: thread.frozenReason,
    });

    await audit(req, {
      action: frozen ? 'thread.freeze' : 'thread.unfreeze',
      targetType: 'thread', targetId: thread.id, after: { reason: reason ?? null },
    });
    res.json({ thread });
  })
);

/** POST /admin/moderation/threads/:id/mute — silence one participant's alerts. */
adminModerationRouter.post(
  '/threads/:id/mute',
  requirePermission('thread.moderate'),
  asyncHandler(async (req, res) => {
    const { userId, muted } = z
      .object({ userId: z.string().min(1), muted: z.boolean() })
      .parse(req.body);
    const row = await prisma.threadParticipant.update({
      where: { threadId_userId: { threadId: req.params.id, userId } },
      data: { muted },
    });
    await audit(req, {
      action: 'thread.mute', targetType: 'thread', targetId: req.params.id,
      after: { userId, muted },
    });
    res.json({ participant: row });
  })
);

/** GET /admin/moderation/messages/search?q= — find a message across all threads. */
adminModerationRouter.get(
  '/messages/search',
  asyncHandler(async (req, res) => {
    const { q, page = 0, pageSize = 50 } = z
      .object({
        q: z.string().min(2).max(120),
        page: z.coerce.number().min(0).default(0),
        pageSize: z.coerce.number().min(1).max(100).default(50),
      })
      .parse(req.query);

    const where = { text: { contains: q, mode: 'insensitive' as const } };
    const [items, total] = await Promise.all([
      prisma.message.findMany({
        where,
        include: { sender: { select: { id: true, fullName: true, phone: true } } },
        orderBy: { createdAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
      }),
      prisma.message.count({ where }),
    ]);
    res.json({ total, page, pageSize, items });
  })
);

// ─────────────────────────────────────────────────────────────
// Reviews
// ─────────────────────────────────────────────────────────────

/** Recompute a listing's aggregate rating from its visible reviews. */
async function recomputeRating(listingId: string) {
  const agg = await prisma.review.aggregate({
    where: { listingId, hiddenAt: null },
    _avg: { rating: true },
    _count: true,
  });
  await prisma.listing.update({
    where: { id: listingId },
    data: { rating: agg._avg.rating ?? null, reviewCount: agg._count },
  });
  cacheBust('listings:');
  return agg;
}

/** GET /admin/moderation/reviews */
adminModerationRouter.get(
  '/reviews',
  asyncHandler(async (req, res) => {
    const { listingId, userId, hidden, page = 0, pageSize = 50 } = z
      .object({
        listingId: z.string().optional(),
        userId: z.string().optional(),
        hidden: z.enum(['true', 'false']).optional(),
        page: z.coerce.number().min(0).default(0),
        pageSize: z.coerce.number().min(1).max(200).default(50),
      })
      .parse(req.query);

    const where = {
      ...(listingId ? { listingId } : {}),
      ...(userId ? { userId } : {}),
      ...(hidden === 'true' ? { hiddenAt: { not: null } } : {}),
      ...(hidden === 'false' ? { hiddenAt: null } : {}),
    };
    const [items, total] = await Promise.all([
      prisma.review.findMany({
        where,
        include: {
          user: { select: { id: true, fullName: true } },
          listing: { select: { id: true, title: true } },
        },
        orderBy: { createdAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
      }),
      prisma.review.count({ where }),
    ]);
    res.json({ total, page, pageSize, items });
  })
);

/** PATCH /admin/moderation/reviews/:id — edit, hide or unhide. */
adminModerationRouter.patch(
  '/reviews/:id',
  requirePermission('review.moderate'),
  asyncHandler(async (req, res) => {
    const patch = z
      .object({
        rating: z.number().int().min(1).max(5).optional(),
        text: z.string().max(2000).nullish(),
        hidden: z.boolean().optional(),
        hiddenReason: z.string().max(300).nullish(),
      })
      .parse(req.body);

    const before = await prisma.review.findUnique({ where: { id: req.params.id } });
    if (!before) throw new ApiError(404, 'Avis introuvable', 'NOT_FOUND');

    const review = await prisma.review.update({
      where: { id: req.params.id },
      data: {
        rating: patch.rating,
        text: patch.text,
        hiddenAt: patch.hidden === undefined ? undefined : patch.hidden ? new Date() : null,
        hiddenReason: patch.hidden === false ? null : patch.hiddenReason,
      },
    });

    // Hiding a review or changing its score changes the listing's average, so
    // the aggregate has to be recomputed or the star rating goes stale.
    await recomputeRating(review.listingId);

    await audit(req, {
      action: 'review.moderate', targetType: 'review', targetId: review.id,
      before: { rating: before.rating, hiddenAt: before.hiddenAt },
      after: { rating: review.rating, hiddenAt: review.hiddenAt },
    });
    res.json({ review });
  })
);

/** DELETE /admin/moderation/reviews/:id */
adminModerationRouter.delete(
  '/reviews/:id',
  requirePermission('review.moderate'),
  asyncHandler(async (req, res) => {
    const review = await prisma.review.findUnique({ where: { id: req.params.id } });
    if (!review) throw new ApiError(404, 'Avis introuvable', 'NOT_FOUND');
    await prisma.review.delete({ where: { id: review.id } });
    await recomputeRating(review.listingId);
    await audit(req, {
      action: 'review.delete', targetType: 'review', targetId: review.id,
      before: { rating: review.rating, text: review.text },
    });
    res.json({ ok: true });
  })
);

/** POST /admin/moderation/listings/:id/recompute-rating */
adminModerationRouter.post(
  '/listings/:id/recompute-rating',
  requirePermission('listing.moderate'),
  asyncHandler(async (req, res) => {
    const agg = await recomputeRating(req.params.id);
    await audit(req, { action: 'listing.recomputeRating', targetType: 'listing', targetId: req.params.id });
    res.json({ rating: agg._avg.rating, reviewCount: agg._count });
  })
);

// ─────────────────────────────────────────────────────────────
// Reports — one-click resolution
// ─────────────────────────────────────────────────────────────

/**
 * POST /admin/moderation/reports/:id/action — resolve a report and act on it.
 *
 * Bundles the decision and its consequence into one call so a moderator does
 * not have to remember to do the second half. Every branch marks the report
 * ACTIONED, so the queue cannot be left holding a report that was handled.
 */
adminModerationRouter.post(
  '/reports/:id/action',
  requirePermission('report.action'),
  asyncHandler(async (req, res) => {
    const { action, reason, kind, durationMinutes } = z
      .object({
        action: z.enum(['RESTRICT_USER', 'SUSPEND_USER', 'PAUSE_LISTING', 'DELETE_MESSAGE', 'HIDE_REVIEW', 'DISMISS']),
        reason: z.string().max(300).optional(),
        kind: z.string().max(40).optional(),
        durationMinutes: z.number().int().min(1).max(525_600).optional(),
      })
      .parse(req.body);

    const report = await prisma.report.findUnique({ where: { id: req.params.id } });
    if (!report) throw new ApiError(404, 'Signalement introuvable', 'NOT_FOUND');

    const expiresAt = durationMinutes ? new Date(Date.now() + durationMinutes * 60_000) : null;
    let detail: Record<string, unknown> = {};

    switch (action) {
      case 'RESTRICT_USER': {
        if (report.target !== 'USER') {
          throw new ApiError(400, 'Ce signalement ne vise pas un utilisateur.', 'VALIDATION_FAILED');
        }
        const row = await grantRestriction({
          userId: report.targetId,
          kind: (kind as never) ?? 'MESSAGE_SEND',
          reason: reason ?? null,
          expiresAt,
          createdBy: req.userId!,
        });
        emitToUsers([report.targetId], {
          type: 'restriction', kind: row.kind, active: true,
          reason: reason ?? null, expiresAt: expiresAt?.toISOString() ?? null,
        });
        detail = { restrictionId: row.id, kind: row.kind };
        break;
      }
      case 'SUSPEND_USER': {
        await prisma.user.update({
          where: { id: report.targetId },
          data: { isActive: false, tokenVersion: { increment: 1 } },
        });
        detail = { suspended: report.targetId };
        break;
      }
      case 'PAUSE_LISTING': {
        await prisma.listing.update({ where: { id: report.targetId }, data: { status: 'PAUSED' } });
        cacheBust('listings:');
        detail = { paused: report.targetId };
        break;
      }
      case 'DELETE_MESSAGE': {
        await prisma.message.update({
          where: { id: report.targetId },
          data: { deletedAt: new Date(), deletedBy: req.userId!, deleteReason: reason ?? null },
        });
        detail = { deletedMessage: report.targetId };
        break;
      }
      case 'HIDE_REVIEW': {
        const rev = await prisma.review.update({
          where: { id: report.targetId },
          data: { hiddenAt: new Date(), hiddenReason: reason ?? null },
        });
        await recomputeRating(rev.listingId);
        detail = { hiddenReview: report.targetId };
        break;
      }
      case 'DISMISS':
        detail = { dismissed: true };
        break;
    }

    const updated = await prisma.report.update({
      where: { id: report.id },
      data: {
        status: action === 'DISMISS' ? 'DISMISSED' : 'ACTIONED',
        resolution: reason ?? action,
        resolvedAt: new Date(),
      },
    });

    await audit(req, {
      action: `report.${action.toLowerCase()}`,
      targetType: 'report', targetId: report.id,
      before: { status: report.status },
      after: { status: updated.status, ...detail },
    });
    res.json({ report: updated, ...detail });
  })
);

// ─────────────────────────────────────────────────────────────
// Listing moderation extras
// ─────────────────────────────────────────────────────────────

/** POST /admin/moderation/listings/:id/pin — force to the top of search. */
adminModerationRouter.post(
  '/listings/:id/pin',
  requirePermission('listing.pin'),
  asyncHandler(async (req, res) => {
    const { pinned, until } = z
      .object({ pinned: z.boolean(), until: z.coerce.date().optional() })
      .parse(req.body);
    const listing = await prisma.listing.update({
      where: { id: req.params.id },
      data: {
        pinnedAt: pinned ? new Date() : null,
        pinnedUntil: pinned ? (until ?? null) : null,
      },
      select: { id: true, title: true, pinnedAt: true, pinnedUntil: true },
    });
    cacheBust('listings:'); // pinning changes result ordering
    await audit(req, {
      action: pinned ? 'listing.pin' : 'listing.unpin',
      targetType: 'listing', targetId: listing.id,
    });
    res.json({ listing });
  })
);

/** POST /admin/moderation/listings/:id/transfer — hand an annonce to another owner. */
adminModerationRouter.post(
  '/listings/:id/transfer',
  requirePermission('listing.transfer'),
  asyncHandler(async (req, res) => {
    const { newOwnerId } = z.object({ newOwnerId: z.string().min(1) }).parse(req.body);
    const owner = await prisma.user.findUnique({
      where: { id: newOwnerId },
      select: { id: true, isOwner: true },
    });
    if (!owner) throw new ApiError(404, 'Nouveau propriétaire introuvable', 'NOT_FOUND');
    // The receiving account must be able to manage the annonce afterwards, so
    // give it the owner role rather than leaving an unmanageable listing.
    if (!owner.isOwner) {
      await prisma.user.update({ where: { id: owner.id }, data: { isOwner: true } });
    }

    const before = await prisma.listing.findUnique({
      where: { id: req.params.id },
      select: { ownerId: true },
    });
    const listing = await prisma.listing.update({
      where: { id: req.params.id },
      data: { ownerId: newOwnerId },
      select: { id: true, title: true, ownerId: true },
    });
    cacheBust('listings:');
    await audit(req, {
      action: 'listing.transfer', targetType: 'listing', targetId: listing.id,
      before: { ownerId: before?.ownerId }, after: { ownerId: newOwnerId },
    });
    res.json({ listing });
  })
);

/** POST /admin/moderation/listings/:id/boost — grant or extend a boost for free. */
adminModerationRouter.post(
  '/listings/:id/boost',
  requirePermission('listing.boost'),
  asyncHandler(async (req, res) => {
    const { days } = z.object({ days: z.number().int().min(1).max(365) }).parse(req.body);
    const current = await prisma.listing.findUnique({
      where: { id: req.params.id },
      select: { boostExpiresAt: true },
    });
    // Extend from the existing expiry when one is still running, so granting
    // 7 more days to a live boost adds to it instead of shortening it.
    const base =
      current?.boostExpiresAt && current.boostExpiresAt > new Date()
        ? current.boostExpiresAt.getTime()
        : Date.now();
    const expiresAt = new Date(base + days * 24 * 60 * 60 * 1000);

    const listing = await prisma.listing.update({
      where: { id: req.params.id },
      data: {
        status: 'BOOSTED',
        boostDaysLeft: Math.ceil((expiresAt.getTime() - Date.now()) / (24 * 60 * 60 * 1000)),
        boostExpiresAt: expiresAt,
      },
      select: { id: true, title: true, boostExpiresAt: true, ownerId: true },
    });
    cacheBust('listings:');

    await notifyUser({
      userId: listing.ownerId,
      type: 'BOOST',
      title: 'Votre annonce est boostée',
      body: `« ${listing.title} » est mise en avant pendant ${days} jour${days > 1 ? 's' : ''}.`,
    }).catch(() => undefined);

    await audit(req, {
      action: 'listing.boost.grant', targetType: 'listing', targetId: listing.id,
      after: { days, expiresAt },
    });
    res.json({ listing });
  })
);

/** DELETE /admin/moderation/listings/:id/boost */
adminModerationRouter.delete(
  '/listings/:id/boost',
  requirePermission('listing.boost'),
  asyncHandler(async (req, res) => {
    const listing = await prisma.listing.update({
      where: { id: req.params.id },
      data: { status: 'ACTIVE', boostDaysLeft: null, boostExpiresAt: null },
      select: { id: true, title: true, status: true },
    });
    cacheBust('listings:');
    await audit(req, { action: 'listing.boost.revoke', targetType: 'listing', targetId: listing.id });
    res.json({ listing });
  })
);

/** POST /admin/moderation/listings/bulk — act on many annonces at once. */
adminModerationRouter.post(
  '/listings/bulk',
  requirePermission('listing.moderate'),
  asyncHandler(async (req, res) => {
    const { ids, action, reason } = z
      .object({
        ids: z.array(z.string().min(1)).min(1).max(200),
        action: z.enum(['APPROVE', 'REJECT', 'PAUSE', 'ARCHIVE', 'VERIFY', 'UNVERIFY']),
        reason: z.string().max(300).optional(),
      })
      .parse(req.body);

    const data =
      action === 'APPROVE' ? { status: 'ACTIVE' as const }
      : action === 'REJECT' ? { status: 'REJECTED' as const }
      : action === 'PAUSE' ? { status: 'PAUSED' as const }
      : action === 'ARCHIVE' ? { status: 'ARCHIVED' as const, archivedAt: new Date() }
      : action === 'VERIFY' ? { verified: true }
      : { verified: false };

    const { count } = await prisma.listing.updateMany({ where: { id: { in: ids } }, data });
    cacheBust('listings:');

    await audit(req, {
      action: `listing.bulk.${action.toLowerCase()}`,
      targetType: 'listing', targetId: `${ids.length} annonces`,
      after: { ids, reason: reason ?? null },
    });
    res.json({ updated: count });
  })
);
