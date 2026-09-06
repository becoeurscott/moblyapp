import { Request, Response, NextFunction } from 'express';
import { verifyToken } from '../lib/jwt';
import { prisma } from '../lib/prisma';
import { getMaintenance } from '../services/maintenance';

/**
 * Routes that stay reachable while the app is in maintenance.
 *
 * The set is deliberately tiny and matched by prefix against the path *within*
 * the API router (so `/health`, not `/api/v1/health`):
 *
 *  - `/health`      — uptime probes must not go red because of a planned window.
 *  - `/maintenance` — the app polls this to learn when it can come back; if the
 *                     gate blocked it the client could never recover.
 *  - `/auth`        — an admin has to be able to sign in to the dashboard to
 *                     lift the window. Non-admins signing in still hit the wall
 *                     on the very next call.
 *  - `/admin`       — the dashboard itself.
 */
const ALLOW_PREFIXES = ['/health', '/maintenance', '/auth', '/admin'];

/** True when the caller presents a valid token belonging to an admin. */
async function isAdminRequest(req: Request): Promise<boolean> {
  const [scheme, token] = (req.headers.authorization ?? '').split(' ');
  if (scheme !== 'Bearer' || !token) return false;
  try {
    const payload = verifyToken(token);
    const user = await prisma.user.findUnique({
      where: { id: payload.sub },
      select: { isAdmin: true },
    });
    return user?.isAdmin === true;
  } catch {
    return false;
  }
}

/**
 * Blocks the public API while a maintenance window is open.
 *
 * Answers 503 with the same `{ error, code, requestId }` contract as every
 * other failure, plus the window details so a client that was mid-session can
 * render the countdown without a second round-trip. Admins pass through, which
 * is what makes the window liftable from inside.
 */
export async function maintenanceGate(req: Request, res: Response, next: NextFunction) {
  const path = req.path;
  if (ALLOW_PREFIXES.some((p) => path === p || path.startsWith(`${p}/`))) return next();

  const state = await getMaintenance();
  if (!state.enabled) return next();

  if (await isAdminRequest(req)) return next();

  res.status(503).json({
    error: state.message || 'Mobly est en maintenance. Nous revenons très vite.',
    code: 'MAINTENANCE',
    maintenance: {
      enabled: true,
      message: state.message,
      endsAt: state.endsAt ? state.endsAt.toISOString() : null,
      serverTime: new Date().toISOString(),
    },
  });
}
