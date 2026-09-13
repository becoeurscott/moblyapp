import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { serializeMessage } from '../lib/serialize';
import { requireAuth } from '../middleware/auth';
import { writeLimiter } from '../middleware/security';
import { broadcastMessage, isOnline, emitToUsers } from '../realtime/hub';
import { notifyUser } from '../services/push';
import {
  featureGate,
  restrictionGate,
  callerRestricted,
  assertNotBlocked,
} from '../middleware/gates';
import { configSnapshot, getConfig, isFlagEnabled, flagMessage } from '../services/config';
import { isSupportThread } from '../services/support';
import { runSupportAgent, supportAgentReady } from '../services/supportAgent';

export const chatRouter = Router();

/** Fields the client needs about the other person in a thread. */
const userSelect = {
  id: true,
  fullName: true,
  avatarUrl: true,
  avatarColor: true,
  verified: true,
  // Lets the app recognise the support desk and drop the affordances that
  // make no sense there — a listing header, and calling it.
  isSupport: true,
} as const;


/** GET /api/threads — the user's conversations, newest activity first. */
chatRouter.get(
  '/',
  requireAuth,
  asyncHandler(async (req, res) => {
    const parts = await prisma.threadParticipant.findMany({
      // Only conversations that actually have a message. Opening a listing's
      // chat creates the thread immediately, so without this every listing a
      // user merely tapped would sit in their inbox as an empty row.
      where: { userId: req.userId!, thread: { messages: { some: {} } } },
      include: {
        thread: {
          include: {
            listing: {
              select: { id: true, title: true, imageName: true, coverUrl: true, priceFcfa: true, priceUnit: true, ownerId: true },
            },
            participants: { include: { user: { select: userSelect } } },
            messages: { orderBy: { createdAt: 'desc' }, take: 1 },
          },
        },
      },
      orderBy: { thread: { updatedAt: 'desc' } },
    });

    const items = parts.map((p) => {
      const t = p.thread;
      const others = t.participants.filter((x) => x.userId !== req.userId!).map((x) => x.user);
      const last = t.messages[0];
      return {
        id: t.id,
        listing: t.listing,
        participants: others.map((u) => ({ ...u, online: isOnline(u.id) })),
        lastMessage: last ? serializeMessage(last) : null,
        // Read straight off the participant row. The previous version counted
        // unread within the single most recent message it had fetched, so it
        // could only ever report 0 or 1.
        unread: p.unreadCount,
        updatedAt: t.updatedAt,
      };
    });
    res.json({ items });
  })
);

/**
 * POST /api/threads — open (or reuse) a conversation.
 *
 * Pass `listingId` alone and the owner is resolved server-side: the client
 * shouldn't have to know, and shouldn't be trusted to say, who the owner is.
 */
chatRouter.post(
  '/',
  requireAuth,
  featureGate('chat.enabled'),
  restrictionGate('CONTACT_OWNER'),
  writeLimiter,
  asyncHandler(async (req, res) => {
    const { listingId, otherUserId } = z
      .object({ listingId: z.string().optional(), otherUserId: z.string().optional() })
      .parse(req.body);

    let peerId = otherUserId;
    if (listingId) {
      const listing = await prisma.listing.findUnique({
        where: { id: listingId },
        select: { ownerId: true },
      });
      if (!listing) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
      // Only DERIVE the peer from the listing when the caller didn't name one.
      // This used to overwrite `otherUserId` unconditionally, which meant an
      // owner opening a chat from their own visit inbox got peer = themselves
      // and a 422 — the "Impossible d'ouvrir la conversation" alert. The
      // listing is still fetched above so an invalid listingId 404s.
      if (!peerId) peerId = listing.ownerId;
    }
    if (!peerId) {
      throw new ApiError(422, 'Destinataire manquant', 'VALIDATION_FAILED');
    }
    if (peerId === req.userId!) {
      throw new ApiError(422, 'Vous ne pouvez pas vous écrire à vous-même', 'VALIDATION_FAILED');
    }
    // An explicit peer is client-supplied. Accepting it unconditionally would
    // turn this route into "DM any user id you can guess" — an unsolicited-
    // message vector that the listing-derived path never had. So require a
    // real prior relationship: an existing thread, or a visit request between
    // the two of them. Owners reaching a visitor from their inbox satisfy the
    // second; nobody else gets a free channel.
    if (otherUserId) {
      const peer = await prisma.user.findUnique({
        where: { id: peerId }, select: { id: true },
      });
      if (!peer) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');

      const [sharedVisit, sharedThread] = await Promise.all([
        prisma.visitRequest.findFirst({
          where: {
            OR: [
              { ownerId: req.userId!, visitorId: peerId },
              { ownerId: peerId, visitorId: req.userId! },
            ],
          },
          select: { id: true },
        }),
        prisma.thread.findFirst({
          where: {
            AND: [
              { participants: { some: { userId: req.userId! } } },
              { participants: { some: { userId: peerId } } },
            ],
          },
          select: { id: true },
        }),
      ]);
      if (!sharedVisit && !sharedThread) {
        throw new ApiError(403, 'Aucune relation avec cet utilisateur', 'FORBIDDEN');
      }
    }

    /**
     * Return the *whole* thread, not just its id.
     *
     * GET /threads hides conversations with no messages, so a caller that
     * created one and then re-fetched the list would find nothing — which is
     * exactly how the "Message l'hôte" button broke. Handing back the full
     * shape lets the client open the conversation immediately.
     */
    const include = {
      listing: {
        select: { id: true, title: true, imageName: true, coverUrl: true, priceFcfa: true, priceUnit: true, ownerId: true },
      },
      participants: { include: { user: { select: userSelect } } },
      messages: { orderBy: { createdAt: 'desc' as const }, take: 1 },
    };

    const serializeThread = (t: {
      id: string;
      listing: unknown;
      participants: { userId: string; user: { id: string } }[];
      messages: Parameters<typeof serializeMessage>[0][];
      updatedAt: Date;
    }) => ({
      id: t.id,
      listing: t.listing,
      participants: t.participants
        .filter((p) => p.userId !== req.userId!)
        .map((p) => ({ ...p.user, online: isOnline(p.user.id) })),
      lastMessage: t.messages[0] ? serializeMessage(t.messages[0]) : null,
      unread: 0,
      updatedAt: t.updatedAt,
    });

    const existing = await prisma.thread.findFirst({
      where: {
        listingId: listingId ?? null,
        AND: [
          { participants: { some: { userId: req.userId! } } },
          { participants: { some: { userId: peerId } } },
        ],
      },
      include,
    });
    if (existing) {
      return res.json({ thread: serializeThread(existing as never), created: false });
    }

    const thread = await prisma.thread.create({
      data: {
        listingId,
        participants: { create: [{ userId: req.userId! }, { userId: peerId }] },
      },
      include,
    });
    // Log the contact + bump the denormalised counter on the listing. Both
    // feed the owner stats view (Contacts card + contact-rate + per-day
    // breakdown when charted against ContactEvent.createdAt).
    if (listingId) {
      prisma.contactEvent.create({
        data: { listingId, visitorId: req.userId!, method: 'CHAT' },
      }).catch(() => {});
      prisma.listing.update({
        where: { id: listingId },
        data: { contacts: { increment: 1 } },
      }).catch(() => {});
    }
    res.status(201).json({ thread: serializeThread(thread as never), created: true });
  })
);

async function assertParticipant(threadId: string, userId: string) {
  const p = await prisma.threadParticipant.findUnique({
    where: { threadId_userId: { threadId, userId } },
  });
  if (!p) throw new ApiError(403, 'Vous ne participez pas à cette conversation', 'FORBIDDEN');
  return p;
}

/**
 * GET /api/threads/:id/messages — one page, oldest-first.
 *
 * Paginated by cursor: a long-running conversation would otherwise return
 * every message ever sent on each open.
 */
chatRouter.get(
  '/:id/messages',
  requireAuth,
  asyncHandler(async (req, res) => {
    await assertParticipant(req.params.id, req.userId!);
    const { limit, before } = z
      .object({
        limit: z.coerce.number().min(1).max(100).default(50),
        before: z.string().optional(),
      })
      .parse(req.query);

    const messages = await prisma.message.findMany({
      where: {
        threadId: req.params.id,
        deletedAt: null,
        ...(before ? { createdAt: { lt: new Date(before) } } : {}),
      },
      orderBy: { createdAt: 'desc' },
      take: limit,
    });

    // Returned oldest-first so the client can append without reversing.
    const ordered = [...messages].reverse();
    res.json({
      items: ordered.map(serializeMessage),
      nextBefore: messages.length === limit ? messages[messages.length - 1].createdAt : null,
    });
  })
);

/**
 * POST /api/threads/:id/messages
 *
 * Sending is REST, not a socket frame: this way it has a status code, can be
 * retried, and `clientId` makes the retry idempotent. The socket only carries
 * the resulting broadcast.
 */
chatRouter.post(
  '/:id/messages',
  requireAuth,
  featureGate('chat.send'),
  restrictionGate('MESSAGE_SEND'),
  writeLimiter,
  asyncHandler(async (req, res) => {
    await assertParticipant(req.params.id, req.userId!);
    const { text, clientId, kind, mediaUrl, durationSec, replyToId } = z
      .object({
        text: z.string().min(1).max(configSnapshot().limits.messageMaxLength),
        clientId: z.string().min(1).max(64).optional(),
        kind: z.enum(['TEXT', 'IMAGE', 'VOICE', 'SYSTEM']).default('TEXT'),
        mediaUrl: z.string().url().optional(),
        durationSec: z.number().int().positive().optional(),
        replyToId: z.string().optional(),
      })
      .parse(req.body);

    // A frozen thread stays readable but accepts nothing new — the moderation
    // equivalent of closing a comment section rather than deleting it.
    const thread = await prisma.thread.findUnique({
      where: { id: req.params.id },
      select: { frozenAt: true, frozenReason: true },
    });
    if (thread?.frozenAt) {
      throw new ApiError(
        403,
        thread.frozenReason || 'Cette conversation a été gelée par un modérateur.',
        'THREAD_FROZEN'
      );
    }

    // Media and voice are separately switchable, so an operator can keep text
    // chat running while turning off the expensive or abusable parts.
    if (kind === 'IMAGE' || kind === 'VOICE') {
      const doc = await getConfig();
      const mediaFlag = kind === 'VOICE' ? 'chat.voice' : 'chat.media';
      if (!isFlagEnabled(mediaFlag, doc)) {
        throw new ApiError(403, flagMessage(mediaFlag, doc), 'FEATURE_DISABLED');
      }
      if (await callerRestricted(req, 'MESSAGE_MEDIA')) {
        throw new ApiError(
          403,
          'Vous ne pouvez plus envoyer de photos ou de vocaux.',
          'USER_RESTRICTED'
        );
      }
    }

    assertNotBlocked(text);

    // A retry after a timeout must resolve to the message already stored,
    // rather than posting it a second time.
    if (clientId) {
      const dupe = await prisma.message.findUnique({
        where: { threadId_clientId: { threadId: req.params.id, clientId } },
      });
      if (dupe) return res.status(200).json({ message: serializeMessage(dupe), duplicate: true });
    }

    const now = new Date();
    const message = await prisma.message.create({
      data: {
        threadId: req.params.id,
        senderId: req.userId!,
        text,
        clientId,
        kind,
        mediaUrl,
        durationSec,
        replyToId,
      },
    });

    await prisma.$transaction([
      prisma.thread.update({
        where: { id: req.params.id },
        data: { updatedAt: now, lastMessageAt: now },
      }),
      // Bump unread for everyone except the sender, so the threads list can
      // show a real count without scanning messages.
      prisma.threadParticipant.updateMany({
        where: { threadId: req.params.id, userId: { not: req.userId! } },
        data: { unreadCount: { increment: 1 } },
      }),
    ]);

    const payload = serializeMessage(message);

    // Shadow ban: the message is stored and echoed back so the sender sees a
    // normal, successful send, but it is never delivered to anyone else. The
    // point is to make persistent spammers waste their effort instead of
    // immediately registering a new account, which is what an obvious block
    // teaches them to do.
    const shadowBanned = await callerRestricted(req, 'SHADOW_BAN');
    if (!shadowBanned) {
      await broadcastMessage(req.params.id, { ...payload, senderId: req.userId! });
    }

    // Respond first — delivery must not wait on APNs, and a push failure must
    // never fail a message that is already saved and broadcast.
    res.status(201).json({ message: payload });

    if (!shadowBanned) {
      void deliverPush(req.params.id, req.userId!, text).catch((err) =>
        console.error('[push] chat notification failed', err)
      );
    }

    // If this is the support desk, let the assistant have a go. Fire-and-forget
    // and after the response, so a slow or failing model never delays — or
    // fails — the user's own message. Worst case there is no automatic reply
    // and the conversation waits for a human, which is where it would have
    // been anyway.
    if (supportAgentReady() && (await isSupportThread(req.params.id))) {
      void runSupportAgent(req.params.id, req.userId!);
    }
  })
);

/** POST /api/threads/:id/read — mark read (REST twin of the socket event). */
chatRouter.post(
  '/:id/read',
  requireAuth,
  asyncHandler(async (req, res) => {
    await assertParticipant(req.params.id, req.userId!);
    const now = new Date();
    await prisma.$transaction([
      prisma.message.updateMany({
        where: { threadId: req.params.id, senderId: { not: req.userId! }, read: false },
        data: { read: true, readAt: now },
      }),
      prisma.threadParticipant.update({
        where: { threadId_userId: { threadId: req.params.id, userId: req.userId! } },
        data: { unreadCount: 0, lastReadAt: now },
      }),
    ]);

    const others = await prisma.threadParticipant.findMany({
      where: { threadId: req.params.id, userId: { not: req.userId! } },
      select: { userId: true },
    });
    emitToUsers(
      others.map((o) => o.userId),
      { type: 'read', threadId: req.params.id, userId: req.userId!, at: now.toISOString() }
    );
    res.status(204).end();
  })
);


/**
 * Notify the other participants of a new message.
 *
 * Only pushes to people whose socket is closed: someone with the conversation
 * open is already seeing it, and a banner over the live thread is noise.
 */
async function deliverPush(threadId: string, senderId: string, text: string) {
  const [sender, participants, thread] = await Promise.all([
    prisma.user.findUnique({ where: { id: senderId }, select: { fullName: true } }),
    prisma.threadParticipant.findMany({
      where: { threadId, userId: { not: senderId } },
      select: { userId: true, unreadCount: true, muted: true },
    }),
    prisma.thread.findUnique({
      where: { id: threadId },
      select: { listing: { select: { title: true } } },
    }),
  ]);

  for (const p of participants) {
    if (p.muted || isOnline(p.userId)) continue;
    await notifyUser({
      userId: p.userId,
      type: 'message',
      title: sender?.fullName ?? 'Nouveau message',
      // Truncate here rather than letting iOS clip mid-word in the banner.
      body: text.length > 120 ? text.slice(0, 117) + '…' : text,
      payload: {
        threadId,
        ...(thread?.listing?.title ? { listingTitle: thread.listing.title } : {}),
      },
      threadId,
      badge: p.unreadCount,
    });
  }
}
