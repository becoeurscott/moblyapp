import type { RestrictionKind } from '@prisma/client';
import { prisma } from '../lib/prisma';
import { ApiError } from '../lib/http';
import { cacheGet, cacheSet, cacheBust } from '../lib/cache';

/**
 * Per-user capability blocks.
 *
 * A restriction takes one action away from one account — "this user may not
 * send messages" — without suspending them entirely. `LOGIN` is the exception:
 * it is a full ban, and every token-issuing path checks it.
 *
 * Active means `revokedAt IS NULL AND (expiresAt IS NULL OR expiresAt > now)`.
 * Expiry is evaluated on read rather than by a cron, so a temporary block
 * lapses on its own even if nothing is running.
 *
 * Cached briefly per user because `requireAuth` reads them on every request.
 * Any write busts that user's entry, so a block applied from the dashboard is
 * effective on the next call, not up to a TTL later.
 */

const TTL_MS = 30_000;
const KEY = 'restr:';

export interface ActiveRestriction {
  id: string;
  kind: RestrictionKind;
  reason: string | null;
  expiresAt: Date | null;
}

export function bustRestrictions(userId: string) {
  cacheBust(`${KEY}${userId}`);
}

/** Every currently-active restriction for a user. Never throws. */
export async function activeRestrictions(userId: string): Promise<ActiveRestriction[]> {
  const cacheKey = `${KEY}${userId}`;
  const hit = cacheGet<ActiveRestriction[]>(cacheKey);
  if (hit) return hit;

  try {
    const rows = await prisma.userRestriction.findMany({
      where: {
        userId,
        revokedAt: null,
        OR: [{ expiresAt: null }, { expiresAt: { gt: new Date() } }],
      },
      select: { id: true, kind: true, reason: true, expiresAt: true },
      orderBy: { createdAt: 'desc' },
    });
    cacheSet(cacheKey, rows, TTL_MS);
    return rows;
  } catch (err) {
    // Failing open is deliberate: a database blip must not block every action
    // for every user. The worst case is a restricted user getting one more
    // request through; the alternative is a global outage.
    console.error('[restrictions] read failed, failing open:', err);
    return [];
  }
}

export async function findRestriction(
  userId: string,
  kind: RestrictionKind
): Promise<ActiveRestriction | null> {
  const all = await activeRestrictions(userId);
  return all.find((r) => r.kind === kind) ?? null;
}

export async function hasRestriction(userId: string, kind: RestrictionKind): Promise<boolean> {
  return (await findRestriction(userId, kind)) !== null;
}

/** Default French wording per kind, used when the admin gave no reason. */
const DEFAULT_REASON: Record<RestrictionKind, string> = {
  LOGIN: 'Votre compte a été suspendu.',
  MESSAGE_SEND: 'Vous ne pouvez plus envoyer de messages.',
  MESSAGE_MEDIA: 'Vous ne pouvez plus envoyer de photos ou de vocaux.',
  CALL: 'Les appels sont désactivés sur votre compte.',
  VISIT_REQUEST: 'Vous ne pouvez plus demander de visite.',
  REVIEW_POST: 'Vous ne pouvez plus publier d’avis.',
  LISTING_PUBLISH: 'Vous ne pouvez plus publier d’annonce.',
  LISTING_EDIT: 'Vous ne pouvez plus modifier vos annonces.',
  BOOST: 'Les boosts sont désactivés sur votre compte.',
  FAVORITE: 'Vous ne pouvez plus ajouter de favoris.',
  PROFILE_EDIT: 'Vous ne pouvez plus modifier votre profil.',
  AVATAR_UPLOAD: 'Vous ne pouvez plus changer votre photo de profil.',
  CONTACT_OWNER: 'Vous ne pouvez plus contacter de propriétaire.',
  REPORT_FILE: 'Vous ne pouvez plus envoyer de signalement.',
  BECOME_OWNER: 'Vous ne pouvez pas devenir propriétaire.',
  IDENTITY_VERIFY: 'La vérification d’identité est indisponible sur votre compte.',
  PUSH_RECEIVE: 'Les notifications sont désactivées sur votre compte.',
  SHADOW_BAN: 'Votre contenu est en cours d’examen.',
};

export function restrictionMessage(r: ActiveRestriction): string {
  return r.reason || DEFAULT_REASON[r.kind] || 'Action indisponible sur votre compte.';
}

export interface GrantInput {
  userId: string;
  kind: RestrictionKind;
  reason?: string | null;
  expiresAt?: Date | null;
  createdBy: string;
}

export async function grantRestriction(input: GrantInput) {
  // Revoke any live one of the same kind first, so "extend to 7 days" replaces
  // the old row rather than leaving two rows racing to be found.
  await prisma.userRestriction.updateMany({
    where: { userId: input.userId, kind: input.kind, revokedAt: null },
    data: { revokedAt: new Date(), revokedBy: input.createdBy },
  });

  const row = await prisma.userRestriction.create({
    data: {
      userId: input.userId,
      kind: input.kind,
      reason: input.reason ?? null,
      expiresAt: input.expiresAt ?? null,
      createdBy: input.createdBy,
    },
  });
  bustRestrictions(input.userId);
  return row;
}

export async function revokeRestriction(id: string, revokedBy: string) {
  const row = await prisma.userRestriction.update({
    where: { id },
    data: { revokedAt: new Date(), revokedBy },
  });
  bustRestrictions(row.userId);
  return row;
}

/** The shape handed to the app in `GET /auth/me` and over the socket. */
export function serializeRestriction(r: ActiveRestriction) {
  return {
    kind: r.kind,
    reason: restrictionMessage(r),
    expiresAt: r.expiresAt ? r.expiresAt.toISOString() : null,
  };
}

// ─────────────────────────────────────────────────────────────
// Login gate
// ─────────────────────────────────────────────────────────────

export interface LoginCandidate {
  id: string;
  isActive: boolean;
  lockedUntil?: Date | null;
}

/**
 * The single place that decides whether an account may hold a session.
 *
 * Called by every path that mints or renews a token — password login, OTP
 * verify, OAuth, signup completion and refresh — so a suspended user cannot
 * simply refresh their way back in. Before this existed, `isActive` was a
 * column nothing read and suspension was purely cosmetic.
 */
export async function assertCanLogin(user: LoginCandidate): Promise<void> {
  if (!user.isActive) {
    throw new ApiError(
      403,
      'Votre compte a été suspendu. Contactez le support.',
      'ACCOUNT_SUSPENDED'
    );
  }

  if (user.lockedUntil && user.lockedUntil > new Date()) {
    const mins = Math.max(1, Math.ceil((user.lockedUntil.getTime() - Date.now()) / 60_000));
    throw new ApiError(
      403,
      `Trop de tentatives. Réessayez dans ${mins} minute${mins > 1 ? 's' : ''}.`,
      'ACCOUNT_LOCKED'
    );
  }

  const ban = await findRestriction(user.id, 'LOGIN');
  if (ban) {
    throw new ApiError(403, restrictionMessage(ban), 'ACCOUNT_SUSPENDED', {
      expiresAt: ban.expiresAt ? ban.expiresAt.toISOString() : null,
    });
  }
}
