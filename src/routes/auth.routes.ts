import { Router } from 'express';
import { z } from 'zod';
import bcrypt from 'bcryptjs';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { signToken } from '../lib/jwt';
import { createOtp, verifyOtp, otpLength } from '../services/otp';
import {
  issueRefreshToken,
  rotateRefreshToken,
  revokeRefreshToken,
  revokeAllForUser,
} from '../services/refresh';
import { checkPassword, PASSWORD_RULE_MESSAGES } from '../lib/password';
import { issueResetToken, readResetToken, maskPhone } from '../services/oauth';
import { requireAuth, optionalAuth } from '../middleware/auth';
import {
  authLimiter,
  otpRequestLimiter,
  otpVerifyLimiter,
  smsSendLimiter,
} from '../middleware/security';
import { serializeUser } from '../lib/serialize';

export const authRouter = Router();

/** E.164, defaulting to Cameroon. Same rules as signup.routes.ts. */
function normalizePhone(raw: string): string {
  let s = raw.replace(/[^\d+]/g, '');
  if (s.startsWith('+')) return s;
  if (s.startsWith('00')) return '+' + s.slice(2);
  if (s.startsWith('237')) return '+' + s;
  if (s.startsWith('0')) s = s.slice(1);
  return '+237' + s;
}

/** POST /api/auth/otp/request — send an OTP to a phone number. */
authRouter.post(
  '/otp/request',
  otpRequestLimiter,
  asyncHandler(async (req, res) => {
    const { phone } = z.object({ phone: z.string().min(6) }).parse(req.body);
    const { code, cooldown } = await createOtp(phone);
    if (cooldown) {
      throw new ApiError(
        429,
        `Patientez ${cooldown}s avant de redemander un code`,
        'OTP_RATE_LIMITED'
      );
    }
    // devCode is null unless the server runs in dev mode.
    res.json({ sent: true, devCode: code });
  })
);

/** POST /api/auth/otp/verify — verify OTP, create/return user + JWT. */
authRouter.post(
  '/otp/verify',
  otpVerifyLimiter,
  asyncHandler(async (req, res) => {
    const body = z
      .object({
        phone: z.string().min(6),
        code: z.string().min(4),
        fullName: z.string().min(1).optional(),
        email: z.string().email().optional(),
        isOwner: z.boolean().optional(),
      })
      .parse(req.body);

    const result = await verifyOtp(body.phone, body.code);
    if (result !== 'ok') {
      // Distinct codes so the app can say "code expiré, redemandez-en un"
      // instead of a generic failure the user can't act on.
      const map = {
        invalid: [401, 'Code invalide', 'OTP_INVALID'],
        expired: [401, 'Code expiré, demandez-en un nouveau', 'OTP_EXPIRED'],
        locked: [429, 'Trop de tentatives. Demandez un nouveau code.', 'OTP_LOCKED'],
      } as const;
      const [status, message, code] = map[result];
      throw new ApiError(status, message, code);
    }

    const user0 = await prisma.user.findUnique({ where: { phone: body.phone } });
    if (!user0) {
      // Sign-in only. This route used to create the account silently, which
      // bypassed every signup rule — password policy, e-mail uniqueness, the
      // duplicate warning — and was the one way to get an account that
      // /signup/start would have refused.
      throw new ApiError(
        404,
        'Aucun compte avec ce numéro. Créez un compte.',
        'ACCOUNT_NOT_FOUND'
      );
    }
    let user = user0;
    if (body.fullName || body.email || body.isOwner !== undefined) {
      user = await prisma.user.update({
        where: { id: user.id },
        data: {
          fullName: body.fullName ?? user.fullName,
          email: body.email ?? user.email,
          isOwner: body.isOwner ?? user.isOwner,
        },
      });
    }

    const token = signToken({ sub: user.id, phone: user.phone });
    const refresh = await issueRefreshToken(user.id);
    res.json({
      token,
      refreshToken: refresh.token,
      refreshExpiresAt: refresh.expiresAt,
      user: serializeUser(user),
    });
  })
);

/** POST /api/auth/login — optional password login. */
authRouter.post(
  '/login',
  authLimiter,
  asyncHandler(async (req, res) => {
    const { identifier, password } = z
      .object({ identifier: z.string().min(3), password: z.string().min(6) })
      .parse(req.body);

    // Normalise before lookup: a number typed as "677123456" must still match
    // the stored "+237677123456", otherwise a valid account looks unknown.
    const isEmail = identifier.includes('@');
    const lookup = isEmail ? identifier.trim().toLowerCase() : normalizePhone(identifier);

    const user = await prisma.user.findFirst({
      where: isEmail ? { email: lookup } : { phone: lookup },
    });

    /**
     * Three distinct outcomes, by product decision — the user asked for the
     * error to say which part is wrong rather than one generic message.
     *
     * The trade-off: this confirms whether an address or number is registered,
     * so someone can probe the user base one request at a time. `authLimiter`
     * (20 requests / 15 min per IP) is what keeps that expensive rather than
     * free. If account privacy ever matters more than the clearer error, this
     * is the single place to collapse back to one message.
     */
    if (!user) {
      // Spend a hash anyway so a missing account doesn't answer measurably
      // faster — timing would otherwise leak what the message already says.
      await bcrypt.compare(password, '$2a$10$invalidinvalidinvalidinvalidinvalidinvalidinvalidinvalidinv');
      const err = new ApiError(
        401,
        isEmail
          ? 'Aucun compte avec cet e-mail'
          : 'Aucun compte avec ce numéro',
        'ACCOUNT_NOT_FOUND'
      );
      (err as ApiError & { fields?: Record<string, string> }).fields = {
        identifier: isEmail ? 'Aucun compte avec cet e-mail' : 'Aucun compte avec ce numéro',
      };
      throw err;
    }

    if (!user.passwordHash) {
      // Account exists but was created by OTP or a social provider, so there
      // is no password to check. Point at the route that will actually work.
      throw new ApiError(
        401,
        'Ce compte n’a pas de mot de passe. Connectez-vous par SMS.',
        'NO_PASSWORD_SET'
      );
    }

    const ok = await bcrypt.compare(password, user.passwordHash);
    if (!ok) {
      const err = new ApiError(401, 'Mot de passe incorrect', 'INVALID_PASSWORD');
      (err as ApiError & { fields?: Record<string, string> }).fields = {
        password: 'Mot de passe incorrect',
      };
      throw err;
    }

    const token = signToken({ sub: user.id, phone: user.phone });
    const refresh = await issueRefreshToken(user.id);
    res.json({
      token,
      refreshToken: refresh.token,
      refreshExpiresAt: refresh.expiresAt,
      user: serializeUser(user),
    });
  })
);

/**
 * POST /api/auth/refresh — swap a refresh token for a new pair.
 * Unauthenticated by design: the access token is expected to be expired here.
 */
authRouter.post(
  '/refresh',
  authLimiter,
  asyncHandler(async (req, res) => {
    const { refreshToken } = z
      .object({ refreshToken: z.string().min(20) })
      .parse(req.body);

    const { userId, refresh } = await rotateRefreshToken(refreshToken);
    const user = await prisma.user.findUnique({ where: { id: userId } });
    if (!user) throw new ApiError(401, 'Session invalide', 'UNAUTHENTICATED');

    const token = signToken({ sub: user.id, phone: user.phone });
    res.json({
      token,
      refreshToken: refresh.token,
      refreshExpiresAt: refresh.expiresAt,
      user: serializeUser(user),
    });
  })
);

/** POST /api/auth/logout — revoke this session (or all of them). */
authRouter.post(
  '/logout',
  optionalAuth,
  asyncHandler(async (req, res) => {
    const { refreshToken, allDevices } = z
      .object({ refreshToken: z.string().optional(), allDevices: z.boolean().optional() })
      .parse(req.body ?? {});

    if (allDevices) {
      // Needs a valid access token — we must know whose sessions to kill.
      if (!req.userId) throw new ApiError(401, 'Connexion requise', 'UNAUTHENTICATED');
      await revokeAllForUser(req.userId);
    } else if (refreshToken) {
      await revokeRefreshToken(refreshToken);
    }
    // Always 204: logging out must never fail in a way that strands the client
    // holding credentials it thinks are still live.
    res.status(204).end();
  })
);

/** GET /api/auth/me — current user. */
authRouter.get(
  '/me',
  requireAuth,
  asyncHandler(async (req, res) => {
    const user = await prisma.user.findUnique({ where: { id: req.userId! } });
    if (!user) throw new ApiError(404, 'Utilisateur introuvable', 'NOT_FOUND');
    res.json({ user: serializeUser(user) });
  })
);

/** PATCH /api/auth/me — update profile / become owner. */
authRouter.patch(
  '/me',
  requireAuth,
  asyncHandler(async (req, res) => {
    const body = z
      .object({
        fullName: z.string().min(1).optional(),
        email: z.string().email().optional(),
        isOwner: z.boolean().optional(),
        avatarUrl: z.string().url().optional(),
        /// Hex like "#3A4FF0". Validated so a client can't stuff arbitrary
        /// values (e.g. a URL) into the field.
        avatarColor: z.string().regex(/^#[0-9A-Fa-f]{6}$/).optional(),
        password: z.string().min(6).optional(),
        // Set from the device's reverse-geocoded location. Only the city name
        // is stored — never the coordinate.
        city: z.string().trim().min(1).max(80).optional(),
        region: z.string().trim().min(1).max(80).optional(),
      })
      .parse(req.body);

    const user = await prisma.user.update({
      where: { id: req.userId! },
      data: {
        fullName: body.fullName,
        email: body.email,
        isOwner: body.isOwner,
        avatarUrl: body.avatarUrl,
        avatarColor: body.avatarColor,
        city: body.city,
        region: body.region,
        passwordHash: body.password ? await bcrypt.hash(body.password, 10) : undefined,
      },
    });
    res.json({ user: serializeUser(user) });
  })
);

/**
 * Password reset, in two calls:
 *   1. POST /auth/password/forgot — resolve the account, text a code
 *   2. POST /auth/password/reset  — check the code, set the new password
 *
 * The code goes to the phone on the account, never to whatever number was
 * typed — otherwise anyone could point a reset at a number they control.
 * There is no e-mail reset: no mail provider is wired, and the phone is
 * already the verified identifier.
 */
authRouter.post(
  '/password/forgot',
  smsSendLimiter,
  asyncHandler(async (req, res) => {
    const { identifier } = z.object({ identifier: z.string().min(3) }).parse(req.body);

    const isEmail = identifier.includes('@');
    const lookup = isEmail ? identifier.trim().toLowerCase() : normalizePhone(identifier);
    const user = await prisma.user.findFirst({
      where: isEmail ? { email: lookup } : { phone: lookup },
      select: { id: true, phone: true },
    });

    if (!user) {
      // Consistent with /login, which already distinguishes this case by
      // product decision — hiding it here would only be inconsistent, not
      // private.
      const err = new ApiError(
        404,
        isEmail ? 'Aucun compte avec cet e-mail' : 'Aucun compte avec ce numéro',
        'ACCOUNT_NOT_FOUND'
      );
      (err as ApiError & { fields?: Record<string, string> }).fields = {
        identifier: isEmail ? 'Aucun compte avec cet e-mail' : 'Aucun compte avec ce numéro',
      };
      throw err;
    }

    const { code, cooldown, capped } = await createOtp(user.phone);
    if (capped) {
      throw new ApiError(
        429,
        capped === 'day'
          ? 'Trop de codes demandés aujourd’hui. Réessayez demain.'
          : 'Trop de codes demandés. Réessayez dans une heure.',
        'OTP_RATE_LIMITED'
      );
    }
    if (cooldown) {
      throw new ApiError(
        429,
        `Patientez ${cooldown}s avant de redemander un code`,
        'OTP_RATE_LIMITED'
      );
    }

    // The real number stays inside the signed reset token; the client only
    // gets a masked form to display. Returning it plainly would let anyone
    // holding an e-mail address harvest the phone behind it.
    res.json({
      sent: true,
      maskedPhone: maskPhone(user.phone),
      resetToken: await issueResetToken(user.id, user.phone),
      codeLength: otpLength(),
      devCode: code,
    });
  })
);

authRouter.post(
  '/password/reset',
  otpVerifyLimiter,
  asyncHandler(async (req, res) => {
    const codeLength = otpLength();
    const { resetToken, code, password } = z
      .object({
        resetToken: z.string().min(20),
        code: z.string().length(codeLength),
        password: z.string().min(1),
      })
      .parse(req.body);

    // The account comes from the signed token, not from the request body —
    // otherwise a caller could verify a code they own against someone else's
    // number and reset that account.
    const { userId, phone } = await readResetToken(resetToken);
    const user = await prisma.user.findUnique({ where: { id: userId } });
    if (!user || user.phone !== phone) {
      throw new ApiError(401, 'Session de réinitialisation invalide', 'UNAUTHENTICATED');
    }

    // Validate the new password before spending the code — a rejected password
    // shouldn't force the user to request a fresh SMS.
    const pw = checkPassword(password, [user.fullName, user.email ?? '', phone]);
    if (!pw.ok) {
      const err = new ApiError(422, 'Mot de passe trop faible', 'VALIDATION_FAILED');
      (err as ApiError & { fields?: Record<string, string> }).fields = {
        password: pw.failed.map((r) => PASSWORD_RULE_MESSAGES[r]).join(' · '),
      };
      throw err;
    }

    const result = await verifyOtp(phone, code);
    if (result !== 'ok') {
      const map = {
        invalid: [401, 'Code incorrect', 'OTP_INVALID'],
        expired: [401, 'Code expiré, demandez-en un nouveau', 'OTP_EXPIRED'],
        locked: [429, 'Trop de tentatives. Demandez un nouveau code.', 'OTP_LOCKED'],
      } as const;
      const [status, message, errCode] = map[result];
      throw new ApiError(status, message, errCode);
    }

    await prisma.user.update({
      where: { id: user.id },
      data: { passwordHash: await bcrypt.hash(password, 10) },
    });

    // Kill every other session. If the reset was prompted by a compromise, the
    // attacker's refresh token must not survive the password change.
    await revokeAllForUser(user.id);

    const token = signToken({ sub: user.id, phone: user.phone });
    const refresh = await issueRefreshToken(user.id);
    res.json({
      token,
      refreshToken: refresh.token,
      refreshExpiresAt: refresh.expiresAt,
      user: serializeUser(user),
    });
  })
);
