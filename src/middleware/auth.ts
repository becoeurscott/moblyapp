import { Request, Response, NextFunction } from 'express';
import { TokenExpiredError } from 'jsonwebtoken';
import { verifyToken } from '../lib/jwt';
import { ApiError } from '../lib/http';
import { prisma } from '../lib/prisma';

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      userId?: string;
      user?: { id: string; phone: string; isOwner: boolean; isAdmin: boolean };
    }
  }
}

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
      select: { id: true, phone: true, isOwner: true, isAdmin: true },
    });
    // Token verified but the account is gone — treat as unauthenticated, not
    // expired, so the client signs out instead of looping on refresh.
    if (!user) throw new ApiError(401, 'Session invalide', 'UNAUTHENTICATED');

    req.userId = user.id;
    req.user = user;
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
      select: { id: true, phone: true, isOwner: true, isAdmin: true },
    });
    if (user) {
      req.userId = user.id;
      req.user = user;
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
 * Require an authenticated Mobly admin. `isAdmin` is a flat boolean on
 * `User` — no hierarchical roles for now.
 *
 * Compose with `requireAuth`, since this only checks the flag:
 *   router.get('/admin/foo', requireAuth, requireAdmin, ...)
 */
export function requireAdmin(req: Request, _res: Response, next: NextFunction) {
  if (!req.user?.isAdmin) {
    return next(new ApiError(403, 'Accès admin requis', 'FORBIDDEN'));
  }
  next();
}
