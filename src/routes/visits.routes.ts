import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth, requireOwner } from '../middleware/auth';
import { writeLimiter } from '../middleware/security';
import { notifyUser } from '../services/push';
import { broadcastMessage } from '../realtime/hub';

export const visitsRouter = Router();
export const listingVisitsRouter = Router({ mergeParams: true });

const listingSelect = {
  id: true,
  title: true,
  imageName: true,
  coverUrl: true,
  priceFcfa: true,
  neighborhood: true,
  city: true,
  ownerId: true,
} as const;

const userSelect = {
  id: true,
  fullName: true,
  avatarUrl: true,
  phone: true,
  verified: true,
} as const;

/** Resolve (or create) the chat thread between visitor and owner about a listing. */
async function ensureThread(listingId: string, visitorId: string, ownerId: string): Promise<string> {
  const existing = await prisma.thread.findFirst({
    where: {
      listingId,
      AND: [
        { participants: { some: { userId: visitorId } } },
        { participants: { some: { userId: ownerId } } },
      ],
    },
    select: { id: true },
  });
  if (existing) return existing.id;
  const thread = await prisma.thread.create({
    data: {
      listingId,
      participants: {
        create: [{ userId: visitorId }, { userId: ownerId }],
      },
    },
    select: { id: true },
  });
  return thread.id;
}

const FR_DAYS = ['dimanche', 'lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi'];
const FR_MONTHS = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];

function formatVisitDate(d: Date): string {
  const day = FR_DAYS[d.getDay()];
  const dd = d.getDate();
  const mm = FR_MONTHS[d.getMonth()];
  const hh = String(d.getHours()).padStart(2, '0');
  const mn = String(d.getMinutes()).padStart(2, '0');
  return `${day} ${dd} ${mm} · ${hh}h${mn}`;
}

function visitMessageText(action: string, when: Date): string {
  const stamp = formatVisitDate(when);
  switch (action) {
    case 'REQUESTED':    return `Visite demandée · ${stamp}`;
    case 'CONFIRMED':    return `Visite confirmée · ${stamp}`;
    case 'CANCELLED':    return `Visite annulée · ${stamp}`;
    case 'COMPLETED':    return `Visite terminée · ${stamp}`;
    case 'NO_SHOW':      return `Visite non honorée · ${stamp}`;
    case 'RESCHEDULED':  return `Nouvel horaire proposé · ${stamp}`;
    default:             return `Visite · ${stamp}`;
  }
}

/**
 * Post a SYSTEM message into the visitor↔owner thread for a visit state change.
 * `senderId` is the party who caused the transition; the other party gets the
 * push via broadcastMessage.
 */
async function postVisitSystemMessage(opts: {
  visit: { id: string; listingId: string; visitorId: string; ownerId: string; scheduledAt: Date };
  action: 'REQUESTED' | 'CONFIRMED' | 'CANCELLED' | 'COMPLETED' | 'NO_SHOW' | 'RESCHEDULED';
  senderId: string;
}) {
  const { visit, action, senderId } = opts;
  const threadId = await ensureThread(visit.listingId, visit.visitorId, visit.ownerId);
  const message = await prisma.message.create({
    data: {
      threadId,
      senderId,
      kind: 'SYSTEM',
      text: visitMessageText(action, visit.scheduledAt),
      visitId: visit.id,
      visitAction: action,
    },
  });
  await prisma.thread.update({
    where: { id: threadId },
    data: { updatedAt: new Date() },
  }).catch(() => {});
  await broadcastMessage(threadId, { ...message, senderId });
}

function serializeVisit(v: any) {
  return {
    id: v.id,
    listingId: v.listingId,
    listing: v.listing,
    visitorId: v.visitorId,
    visitor: v.visitor,
    ownerId: v.ownerId,
    owner: v.owner,
    scheduledAt: v.scheduledAt,
    status: v.status,
    note: v.note,
    createdAt: v.createdAt,
    updatedAt: v.updatedAt,
  };
}

/** POST /api/listings/:id/visits — visitor requests a visit. */
listingVisitsRouter.post(
  '/',
  requireAuth,
  writeLimiter,
  asyncHandler(async (req, res) => {
    const parsed = z
      .object({
        scheduledAt: z.string().datetime(),
        note: z.string().max(500).optional(),
      })
      .safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');

    const listingId = req.params.id;
    const listing = await prisma.listing.findUnique({
      where: { id: listingId },
      select: { id: true, ownerId: true, available: true, title: true },
    });
    if (!listing) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
    if (!listing.available) throw new ApiError(409, 'Annonce indisponible', 'CONFLICT');
    if (listing.ownerId === req.userId!) {
      throw new ApiError(400, 'Vous ne pouvez pas visiter votre propre annonce', 'VALIDATION_FAILED');
    }

    const when = new Date(parsed.data.scheduledAt);
    if (when.getTime() < Date.now() - 60_000) {
      throw new ApiError(400, 'La date doit être dans le futur', 'VALIDATION_FAILED');
    }

    const visit = await prisma.visitRequest.create({
      data: {
        listingId,
        visitorId: req.userId!,
        ownerId: listing.ownerId,
        scheduledAt: when,
        note: parsed.data.note ?? null,
      },
      include: {
        listing: { select: listingSelect },
        visitor: { select: userSelect },
        owner: { select: userSelect },
      },
    });

    notifyUser({
      userId: listing.ownerId,
      type: 'visit.requested',
      title: 'Nouvelle demande de visite',
      body: `${visit.visitor.fullName ?? 'Un visiteur'} — ${listing.title}`,
      payload: { visitId: visit.id, listingId: listing.id },
    }).catch(() => {});

    postVisitSystemMessage({
      visit,
      action: 'REQUESTED',
      senderId: req.userId!,
    }).catch(() => {});

    res.status(201).json({ visit: serializeVisit(visit) });
  })
);

/** POST /api/listings/:id/visits/invite — owner-initiated visit invitation. */
listingVisitsRouter.post(
  '/invite',
  requireAuth,
  requireOwner,
  writeLimiter,
  asyncHandler(async (req, res) => {
    const parsed = z
      .object({
        visitorId: z.string().min(1),
        scheduledAt: z.string().datetime(),
        note: z.string().max(500).optional(),
      })
      .safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');

    const listingId = req.params.id;
    const listing = await prisma.listing.findUnique({
      where: { id: listingId },
      select: { id: true, ownerId: true, available: true, title: true },
    });
    if (!listing) throw new ApiError(404, 'Annonce introuvable', 'NOT_FOUND');
    if (listing.ownerId !== req.userId!) throw new ApiError(403, 'Non autorisé', 'FORBIDDEN');
    if (parsed.data.visitorId === req.userId!) {
      throw new ApiError(400, 'Choisissez un visiteur autre que vous', 'VALIDATION_FAILED');
    }

    const visitor = await prisma.user.findUnique({
      where: { id: parsed.data.visitorId },
      select: { id: true, fullName: true },
    });
    if (!visitor) throw new ApiError(404, 'Visiteur introuvable', 'NOT_FOUND');

    const when = new Date(parsed.data.scheduledAt);
    if (when.getTime() < Date.now() - 60_000) {
      throw new ApiError(400, 'La date doit être dans le futur', 'VALIDATION_FAILED');
    }

    const visit = await prisma.visitRequest.create({
      data: {
        listingId,
        visitorId: visitor.id,
        ownerId: listing.ownerId,
        scheduledAt: when,
        note: parsed.data.note ?? null,
      },
      include: {
        listing: { select: listingSelect },
        visitor: { select: userSelect },
        owner: { select: userSelect },
      },
    });

    notifyUser({
      userId: visitor.id,
      type: 'visit.invited',
      title: 'Proposition de visite',
      body: `${visit.owner?.fullName ?? 'Le propriétaire'} — ${listing.title}`,
      payload: { visitId: visit.id, listingId: listing.id },
    }).catch(() => {});

    postVisitSystemMessage({
      visit,
      action: 'REQUESTED',
      senderId: req.userId!,
    }).catch(() => {});

    res.status(201).json({ visit: serializeVisit(visit) });
  })
);

/** GET /api/owner/visits — visits addressed to the current owner. */
visitsRouter.get(
  '/owner/visits',
  requireAuth,
  requireOwner,
  asyncHandler(async (req, res) => {
    const items = await prisma.visitRequest.findMany({
      where: { ownerId: req.userId! },
      include: {
        listing: { select: listingSelect },
        visitor: { select: userSelect },
        owner: { select: userSelect },
      },
      orderBy: [{ status: 'asc' }, { scheduledAt: 'asc' }],
    });
    res.json({ items: items.map(serializeVisit) });
  })
);

/** GET /api/me/visits — visits the current user has requested. */
visitsRouter.get(
  '/me/visits',
  requireAuth,
  asyncHandler(async (req, res) => {
    const items = await prisma.visitRequest.findMany({
      where: { visitorId: req.userId! },
      include: {
        listing: { select: listingSelect },
        visitor: { select: userSelect },
        owner: { select: userSelect },
      },
      orderBy: { scheduledAt: 'desc' },
    });
    res.json({ items: items.map(serializeVisit) });
  })
);

/** PATCH /api/visits/:id — update status or scheduledAt. */
visitsRouter.patch(
  '/visits/:id',
  requireAuth,
  writeLimiter,
  asyncHandler(async (req, res) => {
    const parsed = z
      .object({
        status: z.enum(['REQUESTED', 'CONFIRMED', 'CANCELLED', 'COMPLETED', 'NO_SHOW']).optional(),
        scheduledAt: z.string().datetime().optional(),
        note: z.string().max(500).optional(),
      })
      .safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');

    const visit = await prisma.visitRequest.findUnique({ where: { id: req.params.id } });
    if (!visit) throw new ApiError(404, 'Demande introuvable', 'NOT_FOUND');

    const isOwner = visit.ownerId === req.userId!;
    const isVisitor = visit.visitorId === req.userId!;
    if (!isOwner && !isVisitor) throw new ApiError(403, 'Non autorisé', 'FORBIDDEN');

    // Transition rules:
    //   - CONFIRMED : either party (whoever is the receiver of a REQUESTED)
    //   - CANCELLED : either party (either can walk away)
    //   - COMPLETED / NO_SHOW : owner only (they're hosting the visit)
    //   - propose new scheduledAt without an explicit status : owner only, and
    //     it flips the visit back to REQUESTED for the visitor to (re-)accept
    const data: any = {};
    if (parsed.data.status) {
      const s = parsed.data.status;
      const visitorCanSet: string[] = ['CONFIRMED', 'CANCELLED'];
      if (isVisitor && !visitorCanSet.includes(s)) {
        throw new ApiError(403, 'Non autorisé', 'FORBIDDEN');
      }
      data.status = s;
    }
    if (parsed.data.scheduledAt) {
      const when = new Date(parsed.data.scheduledAt);
      if (when.getTime() < Date.now() - 60_000) {
        throw new ApiError(400, 'La date doit être dans le futur', 'VALIDATION_FAILED');
      }
      // Only the owner can propose a new time; the visitor accepts or refuses.
      if (isVisitor && !parsed.data.status) {
        throw new ApiError(403, 'Non autorisé', 'FORBIDDEN');
      }
      data.scheduledAt = when;
      if (isOwner && !parsed.data.status) data.status = 'REQUESTED';
    }
    if (parsed.data.note !== undefined) data.note = parsed.data.note;

    const updated = await prisma.visitRequest.update({
      where: { id: visit.id },
      data,
      include: {
        listing: { select: listingSelect },
        visitor: { select: userSelect },
        owner: { select: userSelect },
      },
    });

    // Notify the other party.
    const recipientId = isOwner ? visit.visitorId : visit.ownerId;
    const verb =
      data.status === 'CONFIRMED'
        ? 'confirmée'
        : data.status === 'CANCELLED'
          ? 'annulée'
          : data.status === 'COMPLETED'
            ? 'terminée'
            : data.status === 'NO_SHOW'
              ? 'marquée comme non honorée'
              : data.scheduledAt
                ? 'reprogrammée'
                : 'mise à jour';
    notifyUser({
      userId: recipientId,
      type: 'visit.updated',
      title: `Visite ${verb}`,
      body: updated.listing.title,
      payload: { visitId: updated.id, listingId: updated.listingId },
    }).catch(() => {});

    // Which visible action to log in the chat thread. An owner sending a new
    // scheduledAt without a status is a "propose new time" → RESCHEDULED.
    const chatAction: 'CONFIRMED' | 'CANCELLED' | 'COMPLETED' | 'NO_SHOW' | 'RESCHEDULED' | null =
      data.status === 'CONFIRMED' ? 'CONFIRMED'
      : data.status === 'CANCELLED' ? 'CANCELLED'
      : data.status === 'COMPLETED' ? 'COMPLETED'
      : data.status === 'NO_SHOW' ? 'NO_SHOW'
      : (isOwner && data.scheduledAt && !parsed.data.status) ? 'RESCHEDULED'
      : null;

    if (chatAction) {
      postVisitSystemMessage({
        visit: updated,
        action: chatAction,
        senderId: req.userId!,
      }).catch(() => {});
    }

    res.json({ visit: serializeVisit(updated) });
  })
);
