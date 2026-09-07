import { Router } from 'express';
import { z } from 'zod';
import { randomBytes, createHash } from 'node:crypto';
import { RestrictionKind } from '@prisma/client';
import { prisma } from '../../lib/prisma';
import { asyncHandler, ApiError } from '../../lib/http';
import { requirePermission, assertCanActOnUser } from '../../middleware/auth';
import { requireConfirmation } from '../../middleware/adminSecurity';
import { audit, diff } from '../../lib/audit';
import {
  grantRestriction,
  revokeRestriction,
  bustRestrictions,
  serializeRestriction,
  restrictionMessage,
} from '../../services/restrictions';
import { revokeAllForUser, revokeFamily } from '../../services/refresh';
import { kickUser, emitToUsers, isOnline } from '../../realtime/hub';
import { notifyUser } from '../../services/push';
import { configSnapshot } from '../../services/config';

/**
 * Per-user controls: everything an operator can do to one account.
 *
 * The rule running through this file is that a change must take effect *now*,
 * not at the next cache expiry — so each write busts the restriction cache,
 * pushes a socket event to the affected user, and where the account's access
 * is revoked, closes their sockets outright.
 */
export const adminUsersRouter = Router();

const userSelect = {
  id: true, fullName: true, email: true, phone: true,
  isOwner: true, isAdmin: true, adminRole: true, isActive: true,
  verified: true, identityVerified: true, verifiedAt: true,
  city: true, region: true, neighborhood: true, bio: true, locale: true,
  avatarUrl: true, avatarColor: true, membershipTier: true, membershipExpires: true,
  moblyScore: true, rating: true, adminNote: true,
  failedLoginCount: true, lockedUntil: true,
  createdAt: true, lastSeenAt: true,
} as const;

// ─────────────────────────────────────────────────────────────
// Detail
// ─────────────────────────────────────────────────────────────

/** GET /admin/users/:id/full — everything the detail page shows, in one call. */
adminUsersRouter.get(
  '/:id/full',
  asyncHandler(async (req, res) => {
    const id = req.params.id;
    const user = await prisma.user.findUnique({ where: { id }, select: userSelect });
    if (!user) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');

    const [restrictions, counts, devices, sessions, idChecks, recentAudit] = await Promise.all([
      prisma.userRestriction.findMany({
        where: { userId: id },
        orderBy: { createdAt: 'desc' },
        take: 50,
      }),
      prisma.user.findUnique({
        where: { id },
        select: {
          _count: {
            select: {
              listings: true, reviews: true, messages: true, favorites: true,
              visitsRequested: true, visitsReceived: true, reportsFiled: true,
              devices: true, sessions: true,
            },
          },
        },
      }),
      prisma.device.findMany({
        where: { userId: id },
        select: { id: true, platform: true, appVersion: true, locale: true, lastSeenAt: true, pushToken: true },
        orderBy: { lastSeenAt: 'desc' },
      }),
      prisma.refreshToken.findMany({
        where: { userId: id, revokedAt: null, expiresAt: { gt: new Date() } },
        select: { familyId: true, ip: true, userAgent: true, createdAt: true, expiresAt: true },
        orderBy: { createdAt: 'desc' },
        take: 20,
      }),
      prisma.identityCheck.findMany({
        where: { userId: id },
        orderBy: { createdAt: 'desc' },
        take: 10,
      }),
      prisma.adminAuditLog.findMany({
        where: { targetType: 'user', targetId: id },
        orderBy: { createdAt: 'desc' },
        take: 20,
        include: { actor: { select: { id: true, fullName: true } } },
      }),
    ]);

    const now = new Date();
    res.json({
      user,
      online: isOnline(id),
      counts: counts?._count ?? {},
      // The dashboard needs to distinguish "blocked now" from "was blocked",
      // so the active flag is computed here rather than in the UI.
      restrictions: restrictions.map((r) => ({
        ...r,
        active: !r.revokedAt && (!r.expiresAt || r.expiresAt > now),
        message: restrictionMessage(r),
      })),
      // The push token itself is never sent to the browser — it is a credential
      // that can send notifications to that device. Only its presence matters.
      devices: devices.map(({ pushToken, ...d }) => ({ ...d, hasPush: !!pushToken })),
      sessions,
      identityChecks: idChecks,
      audit: recentAudit,
    });
  })
);

// ─────────────────────────────────────────────────────────────
// Profile edits
// ─────────────────────────────────────────────────────────────

const editable = z.object({
  fullName: z.string().min(1).max(120).optional(),
  email: z.string().email().nullish(),
  phone: z.string().min(6).max(20).optional(),
  city: z.string().max(80).nullish(),
  region: z.string().max(80).nullish(),
  neighborhood: z.string().max(80).nullish(),
  bio: z.string().max(1000).nullish(),
  locale: z.enum(['fr', 'en']).optional(),
  avatarUrl: z.string().url().nullish(),
  avatarColor: z.string().regex(/^#[0-9A-Fa-f]{6}$/).nullish(),
  membershipTier: z.string().max(40).nullish(),
  membershipExpires: z.coerce.date().nullish(),
  moblyScore: z.number().min(0).max(5).nullish(),
  adminNote: z.string().max(2000).nullish(),
  isOwner: z.boolean().optional(),
  verified: z.boolean().optional(),
  identityVerified: z.boolean().optional(),
});

/** PATCH /admin/users/:id — edit any profile field. */
adminUsersRouter.patch(
  '/:id',
  requirePermission('user.edit'),
  asyncHandler(async (req, res) => {
    const patch = editable.parse(req.body);
    await assertCanActOnUser(req, req.params.id);

    const before = await prisma.user.findUnique({ where: { id: req.params.id }, select: userSelect });
    if (!before) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');

    // Setting `identityVerified` by hand must also stamp `verifiedAt`, or the
    // profile shows a verified badge with no date behind it.
    const data: Record<string, unknown> = { ...patch };
    if (patch.identityVerified !== undefined) {
      data.verifiedAt = patch.identityVerified ? new Date() : null;
    }

    const after = await prisma.user.update({
      where: { id: req.params.id },
      data,
      select: userSelect,
    });

    await audit(req, {
      action: 'user.edit',
      targetType: 'user',
      targetId: req.params.id,
      ...diff(before, after, patch),
    });

    // Push the change so the app updates without waiting for a refetch —
    // notably the identity badge, which the user is often watching for.
    emitToUsers([req.params.id], {
      type: 'account',
      identityVerified: after.identityVerified,
      reason: null,
    });

    res.json({ user: after });
  })
);

// ─────────────────────────────────────────────────────────────
// Suspension, force logout, lock
// ─────────────────────────────────────────────────────────────

/** POST /admin/users/:id/suspend — block the account entirely. */
adminUsersRouter.post(
  '/:id/suspend',
  requirePermission('user.suspend'),
  asyncHandler(async (req, res) => {
    const { reason } = z.object({ reason: z.string().max(300).optional() }).parse(req.body ?? {});
    await assertCanActOnUser(req, req.params.id);

    const user = await prisma.user.update({
      where: { id: req.params.id },
      data: { isActive: false },
      select: userSelect,
    });

    // Suspension has to take hold everywhere at once: revoke the refresh
    // tokens so nothing can be renewed, bump the token version so tokens
    // already in flight stop working, and close the sockets so real-time
    // delivery stops too. Setting the flag alone would leave the user online.
    await prisma.user.update({
      where: { id: req.params.id },
      data: { tokenVersion: { increment: 1 } },
    });
    await revokeAllForUser(req.params.id);
    kickUser(req.params.id, reason || 'Votre compte a été suspendu.');

    await audit(req, {
      action: 'user.suspend',
      targetType: 'user',
      targetId: req.params.id,
      before: { isActive: true },
      after: { isActive: false, reason: reason ?? null },
    });
    res.json({ user });
  })
);

/** POST /admin/users/:id/unsuspend */
adminUsersRouter.post(
  '/:id/unsuspend',
  requirePermission('user.suspend'),
  asyncHandler(async (req, res) => {
    const user = await prisma.user.update({
      where: { id: req.params.id },
      data: { isActive: true, failedLoginCount: 0, lockedUntil: null },
      select: userSelect,
    });
    await audit(req, {
      action: 'user.unsuspend', targetType: 'user', targetId: req.params.id,
      before: { isActive: false }, after: { isActive: true },
    });
    res.json({ user });
  })
);

/** POST /admin/users/:id/force-logout — end every session immediately. */
adminUsersRouter.post(
  '/:id/force-logout',
  requirePermission('user.forceLogout'),
  asyncHandler(async (req, res) => {
    await prisma.user.update({
      where: { id: req.params.id },
      data: { tokenVersion: { increment: 1 } },
    });
    await revokeAllForUser(req.params.id);
    const closed = kickUser(req.params.id, 'Votre session a été fermée par un administrateur.');
    await audit(req, { action: 'user.forceLogout', targetType: 'user', targetId: req.params.id });
    res.json({ ok: true, socketsClosed: closed });
  })
);

/** POST /admin/users/:id/unlock — clear a failed-login lockout. */
adminUsersRouter.post(
  '/:id/unlock',
  requirePermission('user.unlock'),
  asyncHandler(async (req, res) => {
    await prisma.user.update({
      where: { id: req.params.id },
      data: { failedLoginCount: 0, lockedUntil: null },
    });
    await audit(req, { action: 'user.unlock', targetType: 'user', targetId: req.params.id });
    res.json({ ok: true });
  })
);

// ─────────────────────────────────────────────────────────────
// Restrictions — "block this user from sending messages"
// ─────────────────────────────────────────────────────────────

/** GET /admin/users/:id/restrictions */
adminUsersRouter.get(
  '/:id/restrictions',
  asyncHandler(async (req, res) => {
    const rows = await prisma.userRestriction.findMany({
      where: { userId: req.params.id },
      orderBy: { createdAt: 'desc' },
    });
    const now = new Date();
    res.json({
      items: rows.map((r) => ({
        ...r,
        active: !r.revokedAt && (!r.expiresAt || r.expiresAt > now),
      })),
      kinds: Object.values(RestrictionKind),
    });
  })
);

/** POST /admin/users/:id/restrictions — take one capability away. */
adminUsersRouter.post(
  '/:id/restrictions',
  requirePermission('user.restrict'),
  asyncHandler(async (req, res) => {
    const { kind, reason, durationMinutes, expiresAt } = z
      .object({
        kind: z.nativeEnum(RestrictionKind),
        reason: z.string().max(300).optional(),
        // Two ways to express the same thing: the dashboard sends preset
        // durations, an API caller may prefer an absolute instant.
        durationMinutes: z.number().int().min(1).max(525_600).optional(),
        expiresAt: z.coerce.date().optional(),
      })
      .parse(req.body);

    await assertCanActOnUser(req, req.params.id);

    const until =
      expiresAt ?? (durationMinutes ? new Date(Date.now() + durationMinutes * 60_000) : null);

    const row = await grantRestriction({
      userId: req.params.id,
      kind,
      reason: reason ?? null,
      expiresAt: until,
      createdBy: req.userId!,
    });

    // A login ban is an eviction, not just a flag: kill the sessions too.
    if (kind === 'LOGIN') {
      await prisma.user.update({
        where: { id: req.params.id },
        data: { tokenVersion: { increment: 1 } },
      });
      await revokeAllForUser(req.params.id);
      kickUser(req.params.id, restrictionMessage(row));
    } else {
      // Everything else leaves them signed in — tell the app so it can disable
      // the control at once instead of waiting for the next `/auth/me`.
      emitToUsers([req.params.id], {
        type: 'restriction',
        kind,
        active: true,
        reason: restrictionMessage(row),
        expiresAt: until ? until.toISOString() : null,
      });
    }

    await audit(req, {
      action: 'user.restrict',
      targetType: 'user',
      targetId: req.params.id,
      after: { kind, reason: reason ?? null, expiresAt: until },
    });
    res.status(201).json({ restriction: row });
  })
);

/** DELETE /admin/users/:id/restrictions/:rid — lift one. */
adminUsersRouter.delete(
  '/:id/restrictions/:rid',
  requirePermission('user.restrict'),
  asyncHandler(async (req, res) => {
    const row = await prisma.userRestriction.findUnique({ where: { id: req.params.rid } });
    if (!row || row.userId !== req.params.id) {
      throw new ApiError(404, 'Restriction introuvable', 'NOT_FOUND');
    }
    const updated = await revokeRestriction(req.params.rid, req.userId!);

    emitToUsers([req.params.id], {
      type: 'restriction',
      kind: row.kind,
      active: false,
      reason: null,
      expiresAt: null,
    });

    await audit(req, {
      action: 'user.unrestrict',
      targetType: 'user',
      targetId: req.params.id,
      before: { kind: row.kind },
    });
    res.json({ restriction: updated });
  })
);

// ─────────────────────────────────────────────────────────────
// Identity (KYC)
// ─────────────────────────────────────────────────────────────

/** POST /admin/users/:id/identity — approve / decline / reset a KYC check. */
adminUsersRouter.post(
  '/:id/identity',
  requirePermission('user.identity'),
  asyncHandler(async (req, res) => {
    const { decision, reason } = z
      .object({
        decision: z.enum(['APPROVE', 'DECLINE', 'RESET']),
        reason: z.string().max(300).optional(),
      })
      .parse(req.body);

    const id = req.params.id;
    const before = await prisma.user.findUnique({
      where: { id },
      select: { identityVerified: true },
    });
    if (!before) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');

    const latest = await prisma.identityCheck.findFirst({
      where: { userId: id },
      orderBy: { createdAt: 'desc' },
    });

    const approved = decision === 'APPROVE';
    const user = await prisma.user.update({
      where: { id },
      data: {
        identityVerified: approved,
        verifiedAt: approved ? new Date() : null,
      },
      select: userSelect,
    });

    // Mirror the decision onto the provider check so the queue reflects it and
    // the reason survives for support to read back.
    if (latest) {
      await prisma.identityCheck.update({
        where: { id: latest.id },
        data: {
          status: approved ? 'APPROVED' : decision === 'DECLINE' ? 'DECLINED' : 'ABANDONED',
          reason: reason ?? null,
          decidedAt: new Date(),
          decidedBy: req.userId!,
        },
      });
    }

    // The user is very often sitting on the verification screen waiting, so
    // both a notification and a live socket event go out.
    await notifyUser({
      userId: id,
      type: 'IDENTITY',
      title: approved ? 'Identité vérifiée' : 'Vérification refusée',
      body: approved
        ? 'Votre identité est confirmée. Vous pouvez publier vos annonces.'
        : reason || 'Votre vérification d’identité n’a pas abouti.',
    }).catch(() => undefined);

    emitToUsers([id], { type: 'account', identityVerified: approved, reason: reason ?? null });

    await audit(req, {
      action: `user.identity.${decision.toLowerCase()}`,
      targetType: 'user',
      targetId: id,
      before: { identityVerified: before.identityVerified },
      after: { identityVerified: approved, reason: reason ?? null },
    });
    res.json({ user });
  })
);

// ─────────────────────────────────────────────────────────────
// Sessions, devices, notifications, export
// ─────────────────────────────────────────────────────────────

/** DELETE /admin/users/:id/sessions/:familyId — revoke one session. */
adminUsersRouter.delete(
  '/:id/sessions/:familyId',
  requirePermission('user.session.revoke'),
  asyncHandler(async (req, res) => {
    await revokeFamily(req.params.familyId);
    await audit(req, {
      action: 'user.session.revoke', targetType: 'user', targetId: req.params.id,
      before: { familyId: req.params.familyId },
    });
    res.json({ ok: true });
  })
);

/** DELETE /admin/users/:id/devices/:deviceId — drop a push target. */
adminUsersRouter.delete(
  '/:id/devices/:deviceId',
  requirePermission('user.device.remove'),
  asyncHandler(async (req, res) => {
    await prisma.device.delete({ where: { id: req.params.deviceId } }).catch(() => {
      throw new ApiError(404, 'Appareil introuvable', 'NOT_FOUND');
    });
    await audit(req, {
      action: 'user.device.remove', targetType: 'user', targetId: req.params.id,
      before: { deviceId: req.params.deviceId },
    });
    res.json({ ok: true });
  })
);

/** GET /admin/users/:id/activity — sessions and events, newest first. */
adminUsersRouter.get(
  '/:id/activity',
  asyncHandler(async (req, res) => {
    const [sessions, events] = await Promise.all([
      prisma.appSession.findMany({
        where: { userId: req.params.id },
        orderBy: { startedAt: 'desc' },
        take: 50,
      }),
      prisma.appEvent.findMany({
        where: { userId: req.params.id },
        orderBy: { createdAt: 'desc' },
        take: 200,
      }),
    ]);
    res.json({ sessions, events });
  })
);

/** POST /admin/users/:id/password-reset-link — mint a one-shot reset code. */
adminUsersRouter.post(
  '/:id/password-reset-link',
  requirePermission('user.passwordReset'),
  asyncHandler(async (req, res) => {
    const user = await prisma.user.findUnique({
      where: { id: req.params.id },
      select: { id: true, phone: true },
    });
    if (!user) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');

    // Same shape as the self-service reset: a random token, stored hashed, with
    // a short life. Support reads the code to the user over the phone; we never
    // store or display anything that could be replayed later.
    const token = randomBytes(4).toString('hex').toUpperCase();
    await prisma.user.update({
      where: { id: user.id },
      data: {
        passwordResetTokenHash: createHash('sha256').update(token).digest('hex'),
        passwordResetExpiresAt: new Date(Date.now() + 30 * 60_000),
      },
    });
    await audit(req, {
      action: 'user.passwordResetLink', targetType: 'user', targetId: user.id,
    });
    res.json({ code: token, expiresInMinutes: 30 });
  })
);

/** POST /admin/users/:id/notify — a targeted push + in-app notification. */
adminUsersRouter.post(
  '/:id/notify',
  requirePermission('user.notify'),
  asyncHandler(async (req, res) => {
    const { title, body, type } = z
      .object({
        title: z.string().min(1).max(120),
        body: z.string().min(1).max(500),
        type: z.string().max(40).default('ANNOUNCEMENT'),
      })
      .parse(req.body);
    await notifyUser({ userId: req.params.id, type, title, body });
    await audit(req, {
      action: 'user.notify', targetType: 'user', targetId: req.params.id, after: { title },
    });
    res.json({ sent: true });
  })
);

/** GET /admin/users/:id/export — everything held about one account (RGPD). */
adminUsersRouter.get(
  '/:id/export',
  requirePermission('user.export'),
  asyncHandler(async (req, res) => {
    const id = req.params.id;
    const user = await prisma.user.findUnique({ where: { id }, select: userSelect });
    if (!user) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');

    const [listings, reviews, visits, favorites, notifications, restrictions] = await Promise.all([
      prisma.listing.findMany({ where: { ownerId: id } }),
      prisma.review.findMany({ where: { userId: id } }),
      prisma.visitRequest.findMany({ where: { OR: [{ visitorId: id }, { ownerId: id }] } }),
      prisma.favorite.findMany({ where: { userId: id } }),
      prisma.notification.findMany({ where: { userId: id } }),
      prisma.userRestriction.findMany({ where: { userId: id } }),
    ]);

    await audit(req, { action: 'user.export', targetType: 'user', targetId: id });
    res.setHeader('Content-Disposition', `attachment; filename="mobly-user-${id}.json"`);
    res.json({ exportedAt: new Date(), user, listings, reviews, visits, favorites, notifications, restrictions });
  })
);

/**
 * POST /admin/users/:id/anonymize — the reversible half of account deletion.
 *
 * Scrubs the personal data but keeps the rows, so conversations and reviews
 * other users depend on do not vanish and leave dangling references. Preferred
 * over `DELETE` for a user exercising their right to erasure.
 */
adminUsersRouter.post(
  '/:id/anonymize',
  requirePermission('user.delete'),
  requireConfirmation((req) => req.params.id),
  asyncHandler(async (req, res) => {
    await assertCanActOnUser(req, req.params.id);
    const id = req.params.id;
    const stamp = Date.now();

    const user = await prisma.user.update({
      where: { id },
      data: {
        fullName: 'Compte supprimé',
        // Phone and email are unique columns, so they are replaced with a
        // unique placeholder rather than nulled — two anonymised accounts
        // would otherwise collide on the second one.
        email: null,
        phone: `deleted-${stamp}-${id.slice(0, 6)}`,
        passwordHash: null,
        avatarUrl: null,
        bio: null,
        whatsappNumber: null,
        isActive: false,
        tokenVersion: { increment: 1 },
      },
      select: userSelect,
    });
    await revokeAllForUser(id);
    kickUser(id, 'Compte supprimé.');
    bustRestrictions(id);

    await audit(req, { action: 'user.anonymize', targetType: 'user', targetId: id });
    res.json({ user });
  })
);

/** GET /admin/restrictions — every active restriction, across all users. */
adminUsersRouter.get(
  '/',
  asyncHandler(async (req, res) => {
    const { kind, page = 0, pageSize = 50 } = z
      .object({
        kind: z.nativeEnum(RestrictionKind).optional(),
        page: z.coerce.number().min(0).default(0),
        pageSize: z.coerce.number().min(1).max(200).default(50),
      })
      .parse(req.query);

    const where = {
      ...(kind ? { kind } : {}),
      revokedAt: null,
      OR: [{ expiresAt: null }, { expiresAt: { gt: new Date() } }],
    };
    const [items, total] = await Promise.all([
      prisma.userRestriction.findMany({
        where,
        include: { user: { select: { id: true, fullName: true, phone: true, avatarColor: true } } },
        orderBy: { createdAt: 'desc' },
        skip: page * pageSize,
        take: pageSize,
      }),
      prisma.userRestriction.count({ where }),
    ]);
    res.json({ total, page, pageSize, items });
  })
);
