import { Request, Response, NextFunction } from 'express';
import rateLimit from 'express-rate-limit';
import { ApiError } from '../lib/http';
import { configSnapshot } from '../services/config';
import { clientIp } from '../lib/audit';

/**
 * Defence in depth for the admin surface.
 *
 * Everything behind `/admin` can ban accounts, delete content and reconfigure
 * the product for every user at once, so a stolen admin token is the worst
 * credential in the system. `requireAdmin` proves *who* is calling; the layers
 * here constrain *from where*, *how fast*, and *how deliberately*.
 */

const READ_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);

/**
 * Optional IP allowlist. Empty (the default) means no restriction, so the
 * feature is inert until an operator deliberately turns it on.
 *
 * `PUT /admin/config` refuses a list that would exclude the caller — locking
 * yourself out of the only tool that can unlock you is a one-way door.
 */
export function adminIpGate(req: Request, _res: Response, next: NextFunction) {
  const allow = configSnapshot().security.adminIpAllowlist;
  if (!allow.length) return next();

  const ip = clientIp(req);
  // A request with no resolvable IP is refused rather than allowed: an
  // allowlist that silently passes unknown origins is not an allowlist.
  if (!ip || !allow.includes(ip)) {
    return next(
      new ApiError(403, 'Accès administrateur refusé depuis cette adresse.', 'ADMIN_IP_BLOCKED')
    );
  }
  next();
}

/**
 * Rate limit on admin *writes* only. Reading the dashboard fires many GETs and
 * should never be throttled; a runaway script hammering PATCH endpoints should.
 * Keyed by admin id so one compromised account cannot exhaust everyone's quota.
 */
export const adminWriteLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  limit: () => configSnapshot().limits.rateLimits.adminWrite,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  skip: (req) => READ_METHODS.has(req.method),
  keyGenerator: (req) => req.userId ?? clientIp(req) ?? 'unknown',
  message: { error: 'Trop de requêtes administrateur. Patientez.', code: 'RATE_LIMITED' },
});

/**
 * Require the operator to have typed a confirmation phrase for an irreversible
 * action. The dashboard collects it and sends it as `x-confirm`; the value must
 * match the id of the thing being destroyed, so a mis-click on the wrong row
 * cannot go through.
 *
 * Turned off wholesale by `security.requireConfirmPhrase: false`.
 */
export function requireConfirmation(getExpected: (req: Request) => string) {
  return (req: Request, _res: Response, next: NextFunction) => {
    if (!configSnapshot().security.requireConfirmPhrase) return next();

    const header = req.headers['x-confirm'];
    const provided = (typeof header === 'string' ? header : (req.body?.confirm as string)) ?? '';
    const expected = getExpected(req);

    if (provided.trim() !== expected) {
      return next(
        new ApiError(
          400,
          'Action irréversible : confirmation requise.',
          'CONFIRMATION_REQUIRED',
          { expected }
        )
      );
    }
    next();
  };
}
