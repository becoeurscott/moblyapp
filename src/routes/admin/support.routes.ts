import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma';
import { asyncHandler, ApiError } from '../../lib/http';
import { requirePermission } from '../../middleware/auth';
import { audit } from '../../lib/audit';
import { serializeMessage } from '../../lib/serialize';
import { getSupportUser, isSupportThread } from '../../services/support';
import { broadcastMessage, isOnline } from '../../realtime/hub';
import { notifyUser } from '../../services/push';
import { configSnapshot } from '../../services/config';

/**
 * The support inbox: reading user conversations and answering them.
 *
 * This is the only place in the admin surface that *writes* a chat message.
 * Everything else can read, freeze, mute or delete — replying is deliberately
 * narrower, and only ever sends as the shared support identity, never as the
 * admin's own account.
 */
export const adminSupportRouter = Router();

/** GET /admin/support/threads — every support conversation, busiest first. */
adminSupportRouter.get(
  '/threads',
  asyncHandler(async (req, res) => {
    const { query, unread, page = 0, pageSize = 30 } = z
      .object({
        query: z.string().optional(),
        unread: z.enum(['all', 'unread']).optional(),
        page: z.coerce.number().min(0).default(0),
        pageSize: z.coerce.number().min(1).max(100).default(30),
      })
      .parse(req.query);

    const support = await getSupportUser();
    const search = query?.trim();

    const where = {
      participants: { some: { userId: support.id } },
      ...(search
        ? {
            AND: [
              {
                participants: {
                  some: {
                    userId: { not: support.id },
                    user: {
                      OR: [
                        { fullName: { contains: search, mode: 'insensitive' as const } },
                        { phone: { contains: search } },
                        { email: { contains: search, mode: 'insensitive' as const } },
                      ],
                    },
                  },
                },
              },
            ],
          }
        : {}),
      // A thread with no message is one the user opened and abandoned before
      // typing — noise in an inbox meant for questions awaiting an answer.
      messages: { some: {} },
      ...(unread === 'unread'
        ? { participants: { some: { userId: support.id, unreadCount: { gt: 0 } } } }
        : {}),
    };

    const [total, items] = await Promise.all([
      prisma.thread.count({ where }),
      prisma.thread.findMany({
        where,
        orderBy: { lastMessageAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
        include: {
          participants: {
            include: {
              user: {
                select: {
                  id: true, fullName: true, phone: true, email: true,
                  avatarUrl: true, avatarColor: true, isOwner: true,
                  identityVerified: true, isActive: true,
                },
              },
            },
          },
          messages: { orderBy: { createdAt: 'desc' }, take: 1 },
          _count: { select: { messages: true } },
        },
      }),
    ]);

    res.json({
      total,
      page,
      pageSize,
      items: items.map((t) => {
        const user = t.participants.find((p) => p.userId !== support.id)?.user ?? null;
        const desk = t.participants.find((p) => p.userId === support.id);
        return {
          id: t.id,
          user: user ? { ...user, online: isOnline(user.id) } : null,
          // Unread from support's side: how many the user sent that nobody on
          // the team has opened yet. That is the number an agent triages by.
          unread: desk?.unreadCount ?? 0,
          messageCount: t._count.messages,
          lastMessage: t.messages[0] ? serializeMessage(t.messages[0]) : null,
          frozenAt: t.frozenAt,
          updatedAt: t.updatedAt,
        };
      }),
    });
  })
);

/** GET /admin/support/threads/:id — full transcript, oldest first. */
adminSupportRouter.get(
  '/threads/:id',
  asyncHandler(async (req, res) => {
    const support = await getSupportUser();
    const thread = await prisma.thread.findUnique({
      where: { id: req.params.id },
      include: {
        participants: {
          include: {
            user: {
              select: {
                id: true, fullName: true, phone: true, email: true,
                avatarUrl: true, avatarColor: true, isOwner: true,
                identityVerified: true, isActive: true, city: true, createdAt: true,
              },
            },
          },
        },
      },
    });
    if (!thread) throw new ApiError(404, 'Conversation introuvable', 'NOT_FOUND');

    const messages = await prisma.message.findMany({
      where: { threadId: thread.id },
      orderBy: { createdAt: 'asc' },
      take: 500,
      include: { sender: { select: { id: true, fullName: true, avatarColor: true } } },
    });

    // Opening the transcript is what "reading" means for the team, so clear
    // support's unread counter here rather than leaving every conversation
    // permanently marked unread.
    await prisma.threadParticipant
      .update({
        where: { threadId_userId: { threadId: thread.id, userId: support.id } },
        data: { unreadCount: 0, lastReadAt: new Date() },
      })
      .catch(() => undefined); // not a support thread — nothing to clear

    const user = thread.participants.find((p) => p.userId !== support.id)?.user ?? null;
    res.json({
      thread: {
        id: thread.id,
        frozenAt: thread.frozenAt,
        frozenReason: thread.frozenReason,
        updatedAt: thread.updatedAt,
      },
      user: user ? { ...user, online: isOnline(user.id) } : null,
      supportUserId: support.id,
      items: messages.map((m) => ({
        ...serializeMessage(m),
        deletedAt: m.deletedAt,
        sender: m.sender,
      })),
    });
  })
);

/**
 * POST /admin/support/threads/:id/messages — answer as Mobly Support.
 *
 * Sent from the shared identity, not the admin's account, so the user sees one
 * consistent contact. The audit entry records who actually typed it, which is
 * what makes the shared identity safe rather than anonymous.
 */
adminSupportRouter.post(
  '/threads/:id/messages',
  requirePermission('user.notify'),
  asyncHandler(async (req, res) => {
    const { text } = z
      .object({ text: z.string().min(1).max(configSnapshot().limits.messageMaxLength) })
      .parse(req.body);

    const threadId = req.params.id;
    if (!(await isSupportThread(threadId))) {
      throw new ApiError(
        403,
        "Cette conversation n'est pas un fil de support.",
        'FORBIDDEN'
      );
    }

    const support = await getSupportUser();
    const now = new Date();

    const [message] = await prisma.$transaction([
      prisma.message.create({
        data: { threadId, senderId: support.id, kind: 'TEXT', text },
      }),
      prisma.thread.update({
        where: { id: threadId },
        data: { lastMessageAt: now, updatedAt: now },
      }),
      // Bump the *user's* unread, not support's — the reply is unread for them.
      prisma.threadParticipant.updateMany({
        where: { threadId, userId: { not: support.id } },
        data: { unreadCount: { increment: 1 } },
      }),
      // Answering is also reading: clear support's own counter so a replied
      // conversation drops out of the unread queue.
      prisma.threadParticipant.updateMany({
        where: { threadId, userId: support.id },
        data: { unreadCount: 0, lastReadAt: now },
      }),
    ]);

    const payload = serializeMessage(message);
    await broadcastMessage(threadId, { ...payload, senderId: support.id });

    res.status(201).json({ message: payload });

    // Push after responding — a notification failure must never fail a reply
    // that is already saved and delivered over the socket.
    const recipient = await prisma.threadParticipant.findFirst({
      where: { threadId, userId: { not: support.id } },
      select: { userId: true },
    });
    if (recipient) {
      void notifyUser({
        userId: recipient.userId,
        type: 'SUPPORT',
        title: 'Support Mobly',
        body: text.slice(0, 140),
        threadId,
      }).catch((err) => console.error('[support] push failed', err));
    }

    await audit(req, {
      action: 'support.reply',
      targetType: 'thread',
      targetId: threadId,
      after: { text: text.slice(0, 200), sentAs: support.id },
    });
  })
);
