import { Router } from 'express';
import { prisma } from '../lib/prisma';
import { asyncHandler } from '../lib/http';
import { requireAuth } from '../middleware/auth';
import { featureGate } from '../middleware/gates';
import { writeLimiter } from '../middleware/security';
import { serializeMessage } from '../lib/serialize';
import { getOrCreateSupportThread } from '../services/support';
import { isOnline } from '../realtime/hub';

export const supportRouter = Router();

/**
 * `POST /support/thread` — open (or reopen) the caller's conversation with
 * Mobly support.
 *
 * A separate route rather than `POST /threads` with the support id, for two
 * reasons. First, that route refuses an explicit peer the caller has no prior
 * relationship with — a sensible anti-DM rule that would nonetheless 403 the
 * very first support message, since the relationship only exists once a thread
 * does. Second, it is gated on `CONTACT_OWNER`, and a user restricted from
 * messaging owners is precisely the person who most needs to reach support.
 *
 * So this route deliberately bypasses both. It cannot be abused as a DM
 * channel because the recipient is fixed server-side: the caller never names
 * who they are writing to.
 */
supportRouter.post(
  '/thread',
  requireAuth,
  featureGate('support.chat'),
  writeLimiter,
  asyncHandler(async (req, res) => {
    const { threadId, created } = await getOrCreateSupportThread(req.userId!);

    const thread = await prisma.thread.findUnique({
      where: { id: threadId },
      include: {
        participants: {
          include: {
            user: {
              select: {
                id: true, fullName: true, avatarUrl: true,
                avatarColor: true, verified: true, isSupport: true,
              },
            },
          },
        },
        messages: { orderBy: { createdAt: 'desc' }, take: 1 },
      },
    });

    const mine = thread!.participants.find((p) => p.userId === req.userId!);
    res.status(created ? 201 : 200).json({
      created,
      thread: {
        id: thread!.id,
        // Support conversations are never about one listing — the user may be
        // asking about their account, a payment, or nothing in particular.
        listing: null,
        participants: thread!.participants
          .filter((p) => p.userId !== req.userId!)
          .map((p) => ({ ...p.user, online: isOnline(p.user.id) })),
        lastMessage: thread!.messages[0] ? serializeMessage(thread!.messages[0]) : null,
        unread: mine?.unreadCount ?? 0,
        updatedAt: thread!.updatedAt,
      },
    });
  })
);
