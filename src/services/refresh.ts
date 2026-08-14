import { createHash, randomBytes } from 'node:crypto';
import { prisma } from '../lib/prisma';
import { ApiError } from '../lib/http';
import { env } from '../config/env';

/**
 * Rotating refresh tokens with reuse detection.
 *
 * RFC 9700 (BCP 240) requires refresh tokens issued to public clients — which
 * a mobile app is, since it can't hold a client secret — to be either
 * sender-constrained or rotated on every use. We rotate.
 *
 * The token is an opaque random string, not a JWT: there's nothing to read out
 * of it, and it's only valid if it matches a row here, which makes revocation
 * immediate instead of "wait for expiry".
 *
 * Only the SHA-256 of the token is stored. A database leak therefore yields
 * nothing usable — unlike the access token, a refresh token is long-lived, so
 * storing it in plaintext would be handing over durable sessions.
 *
 * Reuse detection: each rotation links to its parent through `familyId`. If a
 * token that was already spent comes back, either it was stolen or the real
 * client is replaying — we can't tell which, so the whole family is revoked
 * and the user re-authenticates. That's the property rotation buys.
 */

const REFRESH_TTL_MS = 30 * 24 * 60 * 60 * 1000; // 30 days

function hash(token: string): string {
  return createHash('sha256').update(token).digest('hex');
}

function newToken(): string {
  return randomBytes(48).toString('base64url');
}

export interface IssuedRefresh {
  token: string;
  expiresAt: Date;
}

/** Start a new token family (called on fresh login). */
export async function issueRefreshToken(userId: string): Promise<IssuedRefresh> {
  const token = newToken();
  const expiresAt = new Date(Date.now() + REFRESH_TTL_MS);
  const familyId = randomBytes(16).toString('hex');

  await prisma.refreshToken.create({
    data: { userId, tokenHash: hash(token), familyId, expiresAt },
  });
  return { token, expiresAt };
}

/**
 * Spend a refresh token and return its replacement.
 * Throws if it's unknown, expired, or already spent.
 */
export async function rotateRefreshToken(
  token: string
): Promise<{ userId: string; refresh: IssuedRefresh }> {
  const existing = await prisma.refreshToken.findUnique({
    where: { tokenHash: hash(token) },
  });
  if (!existing) {
    throw new ApiError(401, 'Session expirée, reconnectez-vous', 'UNAUTHENTICATED');
  }

  // Already spent or explicitly revoked → possible theft. We can't distinguish
  // a stolen token from a client replaying, so assume the worst and kill the
  // family; the legitimate user re-authenticates, the attacker gains nothing.
  if (existing.revokedAt) {
    await revokeFamily(existing.familyId);
    throw new ApiError(401, 'Session expirée, reconnectez-vous', 'UNAUTHENTICATED');
  }

  if (existing.expiresAt <= new Date()) {
    throw new ApiError(401, 'Session expirée, reconnectez-vous', 'UNAUTHENTICATED');
  }

  const replacement = newToken();
  const expiresAt = new Date(Date.now() + REFRESH_TTL_MS);

  // Retire the old token and mint its successor atomically — a crash between
  // the two would otherwise either strand the user or leave two live tokens.
  await prisma.$transaction([
    prisma.refreshToken.update({
      where: { id: existing.id },
      data: { revokedAt: new Date() },
    }),
    prisma.refreshToken.create({
      data: {
        userId: existing.userId,
        tokenHash: hash(replacement),
        familyId: existing.familyId,
        parentId: existing.id,
        expiresAt,
      },
    }),
  ]);

  return { userId: existing.userId, refresh: { token: replacement, expiresAt } };
}

/** Revoke every token in a family (reuse detected, or explicit logout). */
export async function revokeFamily(familyId: string): Promise<void> {
  await prisma.refreshToken.updateMany({
    where: { familyId, revokedAt: null },
    data: { revokedAt: new Date() },
  });
}

/** Revoke a single token — the normal logout path. */
export async function revokeRefreshToken(token: string): Promise<void> {
  await prisma.refreshToken.updateMany({
    where: { tokenHash: hash(token), revokedAt: null },
    data: { revokedAt: new Date() },
  });
}

/** Revoke every session for a user ("log out everywhere"). */
export async function revokeAllForUser(userId: string): Promise<void> {
  await prisma.refreshToken.updateMany({
    where: { userId, revokedAt: null },
    data: { revokedAt: new Date() },
  });
}

/** Drop rows that are expired or long revoked. Safe to call periodically. */
export async function pruneRefreshTokens(): Promise<number> {
  const cutoff = new Date(Date.now() - 7 * 24 * 60 * 60 * 1000);
  const { count } = await prisma.refreshToken.deleteMany({
    where: { OR: [{ expiresAt: { lt: new Date() } }, { revokedAt: { lt: cutoff } }] },
  });
  return count;
}

/** Access-token lifetime, surfaced so the client knows when to refresh. */
export const accessTokenTtl = env.jwtExpiresIn;
