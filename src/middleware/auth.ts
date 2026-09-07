import { Request, Response, NextFunction } from 'express';
import { TokenExpiredError } from 'jsonwebtoken';
import type { AdminRole } from '@prisma/client';
import { verifyToken } from '../lib/jwt';
import { ApiError } from '../lib/http';
import { prisma } from '../lib/prisma';
import {
  activeRestrictions,
  restrictionMessage,
  type ActiveRestriction,
} from '../services/restrictions';
import { can, canActOn, type Permission } from '../lib/permissions';

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      userId?: string;
      user?: {
        id: string;
        phone: string;
        isOwner: boolean;
        isAdmin: boolean;
        adminRole: AdminRole | null;
        identityVerified: boolean;
      };
      /**
       * Every active restriction on the caller, loaded once by `requireAuth`
       * so the per-action gates cost nothing extra.
       */
      restrictions?: ActiveRestriction[];
    }
  }
}

/** Fields every authenticated request needs. Kept narrow — this runs on all of them. */
const AUTH_SELECT = {
  id: true,
  phone: true,
  isOwner: true,
  isAdmin: true,
  adminRole: true,
  identityVerified: true,
  isActive: true,
  tokenVersion: true,
} as const;

/** Require a valid Bearer token; attaches req.user. */
export async function requireAuth(req: Request, _res: Response, next: NextFunction) {
  try {
    const header = req.headers.authorization ?? '';
    const [scheme, token] = header.split(' ');
    if (scheme !== 'Bearer' || !token) {
      throw new ApiError(401, 'Connexion requise', 'UNAUTHENTICATED');
    }

    const payload = verifyToken(token);
    const user = await prisma.user.findUnique({
      where: { id: payload.sub },
      select: AUTH_SELECT,
    });
    // Token verified but the account is gone — treat as unauthenticated, not
    // expired, so the client signs out instead of looping on refresh.
    if (!user) throw new ApiError(401, 'Session invalide', 'UNAUTHENTICATED');

    // Suspension is enforced here, on every single request. `isActive` used to
    // be a column nothing read, which meant "suspending" an account from the
    // dashboard changed nothing at all until its token happened to expire.
    //
    // Checked BEFORE the token version even though suspending also bumps it:
    // both would reject the request, but only this branch tells the user why.
    // Reversing the order turns "votre compte a été suspendu" into a generic
    // "session expirée", and the user re-logs in instead of contacting support.
    if (!user.isActive) {
      throw new ApiError(
        403,
        'Votre compte a été suspendu. Contactez le support.',
        'ACCOUNT_SUSPENDED'
      );
    }

    const restrictions = await activeRestrictions(user.id);
    const ban = restrictions.find((r) => r.kind === 'LOGIN');
    if (ban) {
      throw new ApiError(403, restrictionMessage(ban), 'ACCOUNT_SUSPENDED', {
        expiresAt: ban.expiresAt ? ban.expiresAt.toISOString() : null,
      });
    }

    // A bumped token version means an admin (or the user) invalidated every
    // outstanding session on an account that is otherwise fine. Report it as
    // UNAUTHENTICATED rather than expired so the client signs out instead of
    // spending a refresh token that will also be refused.
    if ((payload.tv ?? 0) !== user.tokenVersion) {
      throw new ApiError(401, 'Session expirée, reconnectez-vous', 'UNAUTHENTICATED');
    }

    req.userId = user.id;
    req.user = {
      id: user.id,
      phone: user.phone,
      isOwner: user.isOwner,
      isAdmin: user.isAdmin,
      adminRole: user.adminRole,
      identityVerified: user.identityVerified,
    };
    req.restrictions = restrictions;
    next();
  } catch (err) {
    if (err instanceof ApiError) return next(err);
    // Distinguishing expiry matters: TOKEN_EXPIRED tells the client to spend a
    // refresh token, anything else tells it to sign the user out.
    if (err instanceof TokenExpiredError) {
      return next(new ApiError(401, 'Session expirée', 'TOKEN_EXPIRED'));
    }
    next(new ApiError(401, 'Session invalide', 'UNAUTHENTICATED'));
  }
}

/**
 * Attach the user when a valid token is present, but never reject.
 * Lets browse endpoints personalise (e.g. mark favourites) while staying open
 * to signed-out visitors.
 */
export async function optionalAuth(req: Request, _res: Response, next: NextFunction) {
  const header = req.headers.authorization ?? '';
  const [scheme, token] = header.split(' ');
  if (scheme !== 'Bearer' || !token) return next();
  try {
    const payload = verifyToken(token);
    const user = await prisma.user.findUnique({
      where: { id: payload.sub },
      select: AUTH_SELECT,
    });
    // A suspended or force-logged-out user browses as an anonymous visitor
    // rather than being rejected — these routes are open to signed-out users
    // anyway, and personalising for a banned account would be wrong.
    if (user && user.isActive && (payload.tv ?? 0) === user.tokenVersion) {
      req.userId = user.id;
      req.user = {
        id: user.id,
        phone: user.phone,
        isOwner: user.isOwner,
        isAdmin: user.isAdmin,
        adminRole: user.adminRole,
        identityVerified: user.identityVerified,
      };
      req.restrictions = await activeRestrictions(user.id);
    }
  } catch {
    // A bad or expired token on an optional route is simply "not signed in".
  }
  next();
}

/** Require an authenticated owner. */
export function requireOwner(req: Request, _res: Response, next: NextFunction) {
  if (!req.user?.isOwner) {
    return next(new ApiError(403, 'Compte propriétaire requis', 'OWNER_REQUIRED'));
  }
  next();
}

/**
 * Require a verified identity (Didit KYC).
 *
 * Uses the value already loaded by `requireAuth`, so it costs no extra query.
 * Whether it is applied at all is decided per-route by the
 * `flags['owners.identityRequired']` switch — see `middleware/gates.ts`.
 */
export function requireVerified(req: Request, _res: Response, next: NextFunction) {
  if (!req.user?.identityVerified) {
    return next(
      new ApiError(403, "Vérification d'identité requise", 'IDENTITY_REQUIRED')
    );
  }
  next();
}

/**
 * Require any admin. `adminRole` is authoritative; the legacy `isAdmin` boolean
 * is kept in sync and still read by the maintenance gate and the iOS app.
 */
export function requireAdmin(req: Request, _res: Response, next: NextFunction) {
  if (!req.user?.adminRole && !req.user?.isAdmin) {
    return next(new ApiError(403, 'Accès admin requis', 'FORBIDDEN'));
  }
  next();
}

/**
 * Require a specific capability. Every mutating admin endpoint carries one of
 * these, so a MODERATOR cannot reach an ADMIN action by guessing its URL.
 */
export function requirePermission(permission: Permission) {
  return (req: Request, _res: Response, next: NextFunction) => {
    // An account flagged `isAdmin` before roles existed is treated as the
    // lowest tier until a SUPER_ADMIN grades it, rather than as a full admin.
    const role = req.user?.adminRole ?? (req.user?.isAdmin ? 'READ_ONLY' : null);
    if (!can(role, permission)) {
      return next(
        new ApiError(403, "Votre rôle ne permet pas cette action.", 'ROLE_REQUIRED')
      );
    }
    next();
  };
}

/**
 * Guard for actions targeting another account: refuses acting on yourself
 * (self-demotion, self-ban, self-delete) and on an equal or superior admin.
 */
export async function assertCanActOnUser(req: Request, targetUserId: string) {
  if (targetUserId === req.userId) {
    throw new ApiError(
      400,
      'Vous ne pouvez pas effectuer cette action sur votre propre compte.',
      'FORBIDDEN'
    );
  }
  const target = await prisma.user.findUnique({
    where: { id: targetUserId },
    select: { adminRole: true },
  });
  if (!target) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');

  if (!canActOn(req.user?.adminRole, target.adminRole)) {
    throw new ApiError(
      403,
      'Vous ne pouvez pas agir sur un administrateur de rang égal ou supérieur.',
      'ROLE_REQUIRED'
    );
  }
}
