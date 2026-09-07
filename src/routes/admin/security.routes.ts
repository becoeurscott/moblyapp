import { Router } from 'express';
import { z } from 'zod';
import { AdminRole } from '@prisma/client';
import { prisma } from '../../lib/prisma';
import { asyncHandler, ApiError } from '../../lib/http';
import { requirePermission, assertCanActOnUser } from '../../middleware/auth';
import { requireConfirmation } from '../../middleware/adminSecurity';
import { audit, clientIp } from '../../lib/audit';
import { revokeFamily } from '../../services/refresh';
import { kickUser, onlineUserIds, onlineCount, broadcastAll } from '../../realtime/hub';
import { ROLE_LABEL, ROLE_RANK, permissionsFor } from '../../lib/permissions';

/** Admin roles, admin sessions, the audit trail, and the emergency levers. */
export const adminSecurityRouter = Router();

/** GET /admin/security/me — who am I and what may I do. */
adminSecurityRouter.get(
  '/me',
  asyncHandler(async (req, res) => {
    const role = req.user?.adminRole ?? null;
    res.json({
      id: req.userId,
      adminRole: role,
      roleLabel: role ? ROLE_LABEL[role] : null,
      permissions: permissionsFor(role),
      ip: clientIp(req),
    });
  })
);

/** GET /admin/security/admins — every account with a role. */
adminSecurityRouter.get(
  '/admins',
  asyncHandler(async (_req, res) => {
    const items = await prisma.user.findMany({
      where: { OR: [{ adminRole: { not: null } }, { isAdmin: true }] },
      select: {
        id: true, fullName: true, email: true, phone: true, adminRole: true,
        isAdmin: true, isActive: true, lastSeenAt: true, createdAt: true,
      },
      orderBy: { createdAt: 'asc' },
    });
    res.json({ items, roles: ROLE_LABEL });
  })
);

/**
 * PATCH /admin/security/admins/:id — grant, change or remove a role.
 *
 * The most dangerous endpoint in the product: it decides who can use every
 * other one. Hence SUPER_ADMIN only, no self-service, and `isAdmin` kept in
 * lockstep because the maintenance gate and the iOS app still read it.
 */
adminSecurityRouter.patch(
  '/admins/:id',
  requirePermission('admin.role.assign'),
  asyncHandler(async (req, res) => {
    const { adminRole } = z
      .object({ adminRole: z.nativeEnum(AdminRole).nullable() })
      .parse(req.body);

    if (req.params.id === req.userId) {
      throw new ApiError(
        400,
        'Vous ne pouvez pas modifier votre propre rôle.',
        'FORBIDDEN'
      );
    }
    await assertCanActOnUser(req, req.params.id);

    const before = await prisma.user.findUnique({
      where: { id: req.params.id },
      select: { adminRole: true, isAdmin: true },
    });
    if (!before) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');

    // Removing the last super admin would leave nobody able to grant roles
    // again — recovery would mean editing the database by hand.
    if (before.adminRole === 'SUPER_ADMIN' && adminRole !== 'SUPER_ADMIN') {
      const others = await prisma.user.count({
        where: { adminRole: 'SUPER_ADMIN', id: { not: req.params.id }, isActive: true },
      });
      if (others === 0) {
        throw new ApiError(
          400,
          'Impossible de retirer le dernier super administrateur.',
          'FORBIDDEN'
        );
      }
    }

    const user = await prisma.user.update({
      where: { id: req.params.id },
      data: { adminRole, isAdmin: adminRole !== null },
      select: { id: true, fullName: true, email: true, adminRole: true, isAdmin: true },
    });

    // A demotion must not leave the old privileges alive in an open dashboard
    // tab, so the sessions go with it.
    await prisma.user.update({
      where: { id: req.params.id },
      data: { tokenVersion: { increment: 1 } },
    });
    kickUser(req.params.id, 'Vos droits administrateur ont changé.');

    await audit(req, {
      action: 'admin.role.assign', targetType: 'user', targetId: req.params.id,
      before: { adminRole: before.adminRole }, after: { adminRole },
    });
    res.json({ user });
  })
);

/** GET /admin/security/sessions — live admin sessions. */
adminSecurityRouter.get(
  '/sessions',
  asyncHandler(async (_req, res) => {
    const items = await prisma.refreshToken.findMany({
      where: {
        revokedAt: null,
        expiresAt: { gt: new Date() },
        user: { OR: [{ adminRole: { not: null } }, { isAdmin: true }] },
      },
      select: {
        id: true, familyId: true, ip: true, userAgent: true, createdAt: true, expiresAt: true,
        user: { select: { id: true, fullName: true, email: true, adminRole: true } },
      },
      orderBy: { createdAt: 'desc' },
      take: 100,
    });
    res.json({ items, online: onlineCount() });
  })
);

/** DELETE /admin/security/sessions/:familyId — end one admin session. */
adminSecurityRouter.delete(
  '/sessions/:familyId',
  requirePermission('admin.session.revoke'),
  asyncHandler(async (req, res) => {
    await revokeFamily(req.params.familyId);
    await audit(req, {
      action: 'admin.session.revoke', targetType: 'session', targetId: req.params.familyId,
    });
    res.json({ ok: true });
  })
);

/**
 * POST /admin/security/force-logout-all — end every session, everywhere.
 *
 * The break-glass control for a suspected token leak. Guarded by the typed
 * confirmation phrase because there is no partial version of it: every user in
 * the country is signed out.
 */
adminSecurityRouter.post(
  '/force-logout-all',
  requirePermission('security.forceLogoutAll'),
  requireConfirmation(() => 'DECONNECTER TOUT LE MONDE'),
  asyncHandler(async (req, res) => {
    const [{ count: bumped }] = await Promise.all([
      prisma.user.updateMany({ data: { tokenVersion: { increment: 1 } } }),
    ]);
    const { count: revoked } = await prisma.refreshToken.updateMany({
      where: { revokedAt: null },
      data: { revokedAt: new Date() },
    });
    const online = onlineUserIds();
    for (const id of online) kickUser(id, 'Session terminée. Reconnectez-vous.');

    await audit(req, {
      action: 'security.forceLogoutAll',
      after: { users: bumped, tokensRevoked: revoked, socketsClosed: online.length },
    });
    res.json({ users: bumped, tokensRevoked: revoked, socketsClosed: online.length });
  })
);

/** GET /admin/security/audit — the trail, filterable. */
adminSecurityRouter.get(
  '/audit',
  asyncHandler(async (req, res) => {
    const q = z
      .object({
        actorId: z.string().optional(),
        action: z.string().optional(),
        targetType: z.string().optional(),
        targetId: z.string().optional(),
        from: z.coerce.date().optional(),
        to: z.coerce.date().optional(),
        page: z.coerce.number().min(0).default(0),
        pageSize: z.coerce.number().min(1).max(200).default(50),
      })
      .parse(req.query);

    const where = {
      ...(q.actorId ? { actorId: q.actorId } : {}),
      ...(q.action ? { action: { startsWith: q.action } } : {}),
      ...(q.targetType ? { targetType: q.targetType } : {}),
      ...(q.targetId ? { targetId: q.targetId } : {}),
      ...(q.from || q.to
        ? { createdAt: { ...(q.from ? { gte: q.from } : {}), ...(q.to ? { lte: q.to } : {}) } }
        : {}),
    };

    const [items, total] = await Promise.all([
      prisma.adminAuditLog.findMany({
        where,
        include: { actor: { select: { id: true, fullName: true, email: true, adminRole: true } } },
        orderBy: { createdAt: 'desc' },
        skip: q.page * q.pageSize,
        take: q.pageSize,
      }),
      prisma.adminAuditLog.count({ where }),
    ]);
    res.json({ total, page: q.page, pageSize: q.pageSize, items });
  })
);

/** GET /admin/security/failed-logins — accounts currently under lockout. */
adminSecurityRouter.get(
  '/failed-logins',
  asyncHandler(async (_req, res) => {
    const items = await prisma.user.findMany({
      where: { OR: [{ failedLoginCount: { gt: 0 } }, { lockedUntil: { not: null } }] },
      select: {
        id: true, fullName: true, email: true, phone: true,
        failedLoginCount: true, lockedUntil: true,
      },
      orderBy: { failedLoginCount: 'desc' },
      take: 100,
    });
    res.json({ items });
  })
);

/** GET /admin/security/online — who is connected right now. */
adminSecurityRouter.get(
  '/online',
  asyncHandler(async (_req, res) => {
    const ids = onlineUserIds();
    const users = await prisma.user.findMany({
      where: { id: { in: ids } },
      select: { id: true, fullName: true, phone: true, avatarColor: true, isOwner: true },
    });
    res.json({ count: ids.length, sockets: onlineCount(), users });
  })
);

/** POST /admin/security/kick/:userId — close a user's sockets without banning. */
adminSecurityRouter.post(
  '/kick/:userId',
  requirePermission('user.forceLogout'),
  asyncHandler(async (req, res) => {
    const closed = kickUser(req.params.userId, 'Connexion fermée par un administrateur.');
    await audit(req, { action: 'user.kick', targetType: 'user', targetId: req.params.userId });
    res.json({ socketsClosed: closed });
  })
);
