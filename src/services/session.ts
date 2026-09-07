import type { Request } from 'express';
import { prisma } from '../lib/prisma';
import { ApiError } from '../lib/http';
import { signToken } from '../lib/jwt';
import { issueRefreshToken, type IssuedRefresh } from './refresh';
import { assertCanLogin } from './restrictions';
import { clientIp } from '../lib/audit';

/**
 * The single way a session is created.
 *
 * Every path that hands out a token — password login, OTP verify, Apple,
 * Google, signup completion — goes through here, so the suspension check and
 * the `tv` claim can never be forgotten on one of them. Before this existed the
 * checks would have had to be repeated at nine call sites, and the one that got
 * missed would have been a silent way back in for a banned account.
 *
 * Costs one extra query per login. Logins are rare and this is the exact moment
 * to spend a round-trip on being certain who we are letting in.
 */
export async function issueSession(
  userId: string,
  phone: string,
  req?: Request
): Promise<{ token: string; refresh: IssuedRefresh }> {
  const user = await prisma.user.findUnique({
    where: { id: userId },
    select: { id: true, isActive: true, tokenVersion: true, lockedUntil: true },
  });
  if (!user) throw new ApiError(401, 'Session invalide', 'UNAUTHENTICATED');

  await assertCanLogin(user);

  const token = signToken({ sub: user.id, phone, tv: user.tokenVersion });
  const refresh = await issueRefreshToken(user.id, {
    ip: req ? clientIp(req) : null,
    userAgent: req?.headers['user-agent']?.slice(0, 500) ?? null,
  });
  return { token, refresh };
}
