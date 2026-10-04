import { createHmac, randomInt, timingSafeEqual } from 'node:crypto';
import { prisma } from '../lib/prisma';
import { env } from '../config/env';
import { ApiError } from '../lib/http';
import { sendEmail, codeEmailHtml, emailConfigured } from './email';

/**
 * Codes sent by e-mail: confirming an address ("verify") and resetting a
 * password ("reset"). Same hygiene as the SMS codes in otp.ts — HMAC at rest,
 * one live code per user+purpose, short TTL, attempt cap, resend cooldown —
 * with six digits, since nothing here is constrained by an SMS template.
 */
export type EmailCodePurpose = 'verify' | 'reset';
export type EmailCodeResult = 'ok' | 'invalid' | 'expired' | 'locked';

export const EMAIL_CODE_LENGTH = 6;
const TTL_MINUTES = 10;
const MAX_ATTEMPTS = 5;
const RESEND_COOLDOWN_MS = 60 * 1000;
/**
 * Per-user caps. They also protect the project-wide InsForge hourly quota: one
 * user hammering "Renvoyer" must not use up the mail budget for everyone.
 */
const HOURLY_CAP = 5;
const DAILY_CAP = 12;

const COPY: Record<EmailCodePurpose, { subject: string; heading: string; intro: string }> = {
  verify: {
    subject: 'Votre code de confirmation Mobly',
    heading: 'Confirmez votre adresse e-mail',
    intro: 'Saisissez ce code dans l’application Mobly pour confirmer votre adresse e-mail.',
  },
  reset: {
    subject: 'Réinitialisation de votre mot de passe Mobly',
    heading: 'Réinitialiser votre mot de passe',
    intro: 'Saisissez ce code dans l’application Mobly pour choisir un nouveau mot de passe.',
  },
};

function hashCode(userId: string, purpose: string, code: string): string {
  return createHmac('sha256', env.jwtSecret).update(`email:${userId}:${purpose}:${code}`).digest('hex');
}

function constantTimeEquals(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  return ab.length === bb.length && timingSafeEqual(ab, bb);
}

/**
 * Issue a code for `userId` and mail it to `email`. Throws 429 on cooldown or
 * cap, 503 if mail can't be sent. Returns the plain code only in OTP dev mode,
 * so the simulator can prefill it — never in production.
 */
export async function sendEmailCode(
  userId: string,
  email: string,
  purpose: EmailCodePurpose
): Promise<{ devCode: string | null }> {
  if (!emailConfigured() && !env.otpDevMode) {
    throw new ApiError(503, 'Service e-mail indisponible', 'INTERNAL');
  }

  const now = Date.now();
  const [hourCount, dayCount, recent] = await Promise.all([
    prisma.emailCode.count({ where: { userId, purpose, createdAt: { gt: new Date(now - 3600_000) } } }),
    prisma.emailCode.count({ where: { userId, purpose, createdAt: { gt: new Date(now - 86_400_000) } } }),
    prisma.emailCode.findFirst({
      where: { userId, purpose },
      orderBy: { createdAt: 'desc' },
      select: { createdAt: true },
    }),
  ]);
  if (dayCount >= DAILY_CAP || hourCount >= HOURLY_CAP) {
    throw new ApiError(
      429,
      dayCount >= DAILY_CAP
        ? 'Trop de codes demandés aujourd’hui. Réessayez demain.'
        : 'Trop de codes demandés. Réessayez dans une heure.',
      'OTP_RATE_LIMITED'
    );
  }
  if (recent) {
    const elapsed = now - recent.createdAt.getTime();
    if (elapsed < RESEND_COOLDOWN_MS) {
      const wait = Math.ceil((RESEND_COOLDOWN_MS - elapsed) / 1000);
      throw new ApiError(429, `Patientez ${wait}s avant de redemander un code`, 'OTP_RATE_LIMITED');
    }
  }

  // Exactly one live code per user+purpose.
  await prisma.emailCode.updateMany({
    where: { userId, purpose, consumed: false },
    data: { consumed: true },
  });

  const code = String(randomInt(0, 10 ** EMAIL_CODE_LENGTH)).padStart(EMAIL_CODE_LENGTH, '0');
  const row = await prisma.emailCode.create({
    data: {
      userId,
      email,
      purpose,
      code: hashCode(userId, purpose, code),
      expiresAt: new Date(now + TTL_MINUTES * 60_000),
    },
  });

  if (emailConfigured()) {
    const copy = COPY[purpose];
    try {
      await sendEmail(email, copy.subject, codeEmailHtml(copy.heading, copy.intro, code, TTL_MINUTES));
    } catch (err) {
      // Never delivered: drop the row so the retry isn't blocked by the
      // cooldown and doesn't count against the user's caps.
      await prisma.emailCode.delete({ where: { id: row.id } }).catch(() => {});
      throw err;
    }
  }

  return { devCode: env.otpDevMode ? code : null };
}

/**
 * Check a code. On success the code is consumed and the address it was sent
 * to is returned — for "verify" that is the address to store on the account.
 */
export async function checkEmailCode(
  userId: string,
  purpose: EmailCodePurpose,
  code: string
): Promise<{ result: EmailCodeResult; email?: string }> {
  const row = await prisma.emailCode.findFirst({
    where: { userId, purpose, consumed: false },
    orderBy: { createdAt: 'desc' },
  });
  if (!row) return { result: 'expired' };
  if (row.expiresAt.getTime() < Date.now()) return { result: 'expired' };
  if (row.attempts >= MAX_ATTEMPTS) return { result: 'locked' };

  if (!constantTimeEquals(row.code, hashCode(userId, purpose, code.trim()))) {
    const updated = await prisma.emailCode.update({
      where: { id: row.id },
      data: { attempts: { increment: 1 } },
      select: { attempts: true },
    });
    return { result: updated.attempts >= MAX_ATTEMPTS ? 'locked' : 'invalid' };
  }

  // Conditional update so two concurrent correct submissions can't both pass.
  const claimed = await prisma.emailCode.updateMany({
    where: { id: row.id, consumed: false },
    data: { consumed: true },
  });
  if (claimed.count === 0) return { result: 'expired' };
  return { result: 'ok', email: row.email };
}

/** Same wording as the SMS paths, so the app maps both the same way. */
export function emailCodeError(result: Exclude<EmailCodeResult, 'ok'>): ApiError {
  const map = {
    invalid: [401, 'Code incorrect', 'OTP_INVALID'],
    expired: [401, 'Code expiré, demandez-en un nouveau', 'OTP_EXPIRED'],
    locked: [429, 'Trop de tentatives. Demandez un nouveau code.', 'OTP_LOCKED'],
  } as const;
  const [status, message, code] = map[result];
  return new ApiError(status, message, code);
}
