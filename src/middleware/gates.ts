import { Request, Response, NextFunction } from 'express';
import type { RestrictionKind } from '@prisma/client';
import { ApiError } from '../lib/http';
import { getConfig, configSnapshot, isFlagEnabled, flagMessage } from '../services/config';
import { activeRestrictions, restrictionMessage } from '../services/restrictions';
import type { FlagKey } from '../config/appConfigSchema';

/**
 * The gates that turn stored configuration into enforced behaviour.
 *
 * Order matters where they are mounted: `requireAuth` first (so the caller and
 * their restrictions are known), then `featureGate` (is this feature on for
 * anyone?), then `restrictionGate` (is it on for *this* user?). Checking the
 * global switch first means a disabled feature reports itself as disabled
 * rather than as a personal sanction.
 */

/** Refuse the request when an admin has switched this feature off. */
export function featureGate(key: FlagKey) {
  return async (_req: Request, _res: Response, next: NextFunction) => {
    try {
      const doc = await getConfig();
      if (!isFlagEnabled(key, doc)) {
        return next(new ApiError(403, flagMessage(key, doc), 'FEATURE_DISABLED', { flag: key }));
      }
      next();
    } catch (err) {
      // A config read failure must not block the feature — fail open, exactly
      // like the maintenance gate does.
      console.error('[gates] featureGate read failed, allowing:', err);
      next();
    }
  };
}

/**
 * Apply another middleware only while a flag is on.
 *
 * Lets a *requirement* be switched remotely rather than a feature — the KYC
 * gate on publishing is the motivating case: `owners.identityRequired` decides
 * whether `requireVerified` runs at all, so the rule can be tightened or
 * relaxed from the dashboard instead of by editing the route.
 */
export function conditionalGate(
  key: FlagKey,
  middleware: (req: Request, res: Response, next: NextFunction) => void
) {
  return async (req: Request, res: Response, next: NextFunction) => {
    try {
      const doc = await getConfig();
      if (!isFlagEnabled(key, doc)) return next();
    } catch {
      // Config unreadable: keep the stricter behaviour. This is the one gate
      // that fails *closed*, because the requirement it guards is a safety
      // rule and skipping it silently would be the worse outcome.
    }
    middleware(req, res, next);
  };
}

/** Refuse the request when this user in particular has been blocked. */
export function restrictionGate(kind: RestrictionKind) {
  return async (req: Request, _res: Response, next: NextFunction) => {
    if (!req.userId) return next();
    try {
      // `requireAuth` has usually loaded these already; fall back for the rare
      // route that gates without it.
      const list = req.restrictions ?? (await activeRestrictions(req.userId));
      const hit = list.find((r) => r.kind === kind);
      if (hit) {
        return next(
          new ApiError(403, restrictionMessage(hit), 'USER_RESTRICTED', {
            restriction: kind,
            expiresAt: hit.expiresAt ? hit.expiresAt.toISOString() : null,
          })
        );
      }
      next();
    } catch (err) {
      console.error('[gates] restrictionGate read failed, allowing:', err);
      next();
    }
  };
}

/** True when the caller carries this restriction — for in-handler branching. */
export async function callerRestricted(req: Request, kind: RestrictionKind): Promise<boolean> {
  if (!req.userId) return false;
  const list = req.restrictions ?? (await activeRestrictions(req.userId));
  return list.some((r) => r.kind === kind);
}

// ─────────────────────────────────────────────────────────────
// Version gate
// ─────────────────────────────────────────────────────────────

/** Compare dotted versions numerically: "1.10.0" is above "1.9.9". */
export function compareVersions(a: string, b: string): number {
  const pa = a.split('.').map((n) => parseInt(n, 10) || 0);
  const pb = b.split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] ?? 0) - (pb[i] ?? 0);
    if (d !== 0) return d < 0 ? -1 : 1;
  }
  return 0;
}

/**
 * Refuse builds older than the configured minimum.
 *
 * The app sends `X-App-Version`; anything that does not (curl, the admin
 * dashboard, an old build predating the header) is let through, because
 * blocking unknown clients would lock out the very dashboard used to lift the
 * setting. `min: "0.0.0"` — the default — disables the gate entirely.
 */
export function versionGate(req: Request, _res: Response, next: NextFunction) {
  const raw = req.headers['x-app-version'];
  const version = typeof raw === 'string' ? raw.trim() : '';
  if (!version || version === 'admin') return next();

  const ios = configSnapshot().versions.ios;
  if (!ios.min || ios.min === '0.0.0') return next();

  if (compareVersions(version, ios.min) < 0) {
    return next(
      new ApiError(426, ios.forceMessage, 'FORCE_UPDATE', {
        update: { minVersion: ios.min, latestVersion: ios.latest, storeUrl: ios.storeUrl },
      })
    );
  }
  next();
}

// ─────────────────────────────────────────────────────────────
// Limits and content
// ─────────────────────────────────────────────────────────────

/** Throw when a numeric limit from the config is exceeded. */
export function assertMax(value: number, max: number, message: string) {
  if (value > max) throw new ApiError(422, message, 'LIMIT_REACHED', { max });
}

/**
 * Reject text containing an admin-configured blocked word.
 *
 * Matched on a normalised copy — accents stripped, case folded — so "arnaque"
 * also catches "ARNAQUE" and "arnaqué". Word list stays server-side; returning
 * which word matched would let a spammer binary-search the blocklist.
 */
export function findBlockedWord(text: string | null | undefined): string | null {
  if (!text) return null;
  const words = configSnapshot().moderation.blockedWords;
  if (!words.length) return null;

  const normalise = (s: string) =>
    s
      .toLowerCase()
      .normalize('NFD')
      .replace(/[̀-ͯ]/g, '');

  const haystack = normalise(text);
  for (const w of words) {
    const needle = normalise(w);
    if (needle && haystack.includes(needle)) return w;
  }
  return null;
}

export function assertNotBlocked(text: string | null | undefined) {
  if (findBlockedWord(text)) {
    throw new ApiError(
      422,
      'Votre message contient des termes interdits sur Mobly.',
      'CONTENT_BLOCKED'
    );
  }
}
