import { createHmac, randomInt, timingSafeEqual } from 'node:crypto';
import { prisma } from '../lib/prisma';
import { env } from '../config/env';
import { sendSms, smsConfigured, isAllowedDestination } from './sms';
import { ApiError } from '../lib/http';

const OTP_TTL_MS = 5 * 60 * 1000; // 5 minutes
/** Digits in a code. */
const OTP_LENGTH = 4;
/**
 * Failures allowed against one code before it's burned.
 *
 * Tightened from 5 to 3 when the code went from 6 digits to 4. Four digits is
 * only 10,000 combinations, so the attempt budget is the entire defence:
 *   3 guesses per code, and PHONE_HOURLY_CAP/PHONE_DAILY_CAP codes per number,
 *   caps a single phone at ~45 guesses/day ≈ 0.45% chance of a hit.
 * Raising any of these three numbers raises that probability directly.
 */
const MAX_ATTEMPTS = 3;
/** Minimum gap between sends to one number. */
const RESEND_COOLDOWN_MS = 60 * 1000;
/**
 * Per-phone send caps. The IP limiter in middleware/security.ts doesn't help
 * here — an attacker rotating IPs against one number would otherwise get
 * unlimited fresh codes, and each fresh code is another 3 guesses.
 */
const PHONE_HOURLY_CAP = 5;
const PHONE_DAILY_CAP = 15;

export type OtpVerifyResult = 'ok' | 'invalid' | 'expired' | 'locked';

/** Exposed so routes can validate length without duplicating the constant. */
export const otpLength = OTP_LENGTH;

/**
 * Codes are stored as an HMAC, never in plaintext.
 *
 * OWASP treats an OTP as an authentication secret deserving password-like
 * hygiene. Four digits is far too little entropy for a slow hash to buy much
 * against a determined offline attack — the real defence is the 5-minute TTL
 * and the attempt caps below — but this does mean a leaked database dump
 * doesn't hand over live codes.
 */
function hashCode(phone: string, code: string): string {
  return createHmac('sha256', env.jwtSecret).update(`${phone}:${code}`).digest('hex');
}

function generateCode(): string {
  // CSPRNG-backed. Math.random is predictable and must never generate anything
  // an attacker benefits from guessing.
  const max = 10 ** OTP_LENGTH;
  return String(randomInt(0, max)).padStart(OTP_LENGTH, '0');
}

function constantTimeEquals(a: string, b: string): boolean {
  const ab = Buffer.from(a);
  const bb = Buffer.from(b);
  if (ab.length !== bb.length) return false;
  return timingSafeEqual(ab, bb);
}

/**
 * Issue an OTP for a phone number and send it.
 *
 * Any previous unconsumed code for that number is retired first, so exactly
 * one code is ever live — otherwise each resend widens the guessing surface.
 * Returns `cooldown` when the caller is asking again too soon; the route turns
 * that into a 429 instead of silently sending another SMS.
 */
export async function createOtp(
  phone: string
): Promise<{ code: string | null; cooldown?: number; capped?: 'hour' | 'day' }> {
  // Reject countries we don't serve before doing any work — this is the
  // SMS-pumping guard, and a blocked destination should never consume the
  // per-phone budget or leave an OTP row behind.
  if (!isAllowedDestination(phone)) {
    throw new ApiError(
      403,
      'Envoi de SMS non disponible vers ce pays pour le moment',
      'FORBIDDEN'
    );
  }

  // Same reasoning as the country check above: if no code can possibly be
  // delivered, fail here rather than after the record exists.
  //
  // This used to be checked at the *end*, after the OTP row had already been
  // written, which made an unconfigured provider look like a rate limit: the
  // first attempt 503'd but left a live row behind, so the retry hit the 60s
  // resend cooldown ("Patientez 59s") and every attempt burned the per-phone
  // hourly/daily caps — five failures in an hour locked the number out over
  // SMS that were never sent.
  if (!smsConfigured() && !env.otpDevMode) {
    throw new ApiError(503, 'Service SMS indisponible', 'INTERNAL');
  }

  // Per-phone volume caps, checked before the cooldown so a caller who has
  // burned their budget is told that, not asked to wait 60s and try again.
  const now = Date.now();
  const [hourCount, dayCount] = await Promise.all([
    prisma.otp.count({ where: { phone, createdAt: { gt: new Date(now - 60 * 60 * 1000) } } }),
    prisma.otp.count({ where: { phone, createdAt: { gt: new Date(now - 24 * 60 * 60 * 1000) } } }),
  ]);
  if (dayCount >= PHONE_DAILY_CAP) return { code: null, capped: 'day' };
  if (hourCount >= PHONE_HOURLY_CAP) return { code: null, capped: 'hour' };

  const recent = await prisma.otp.findFirst({
    where: { phone, consumed: false, expiresAt: { gt: new Date() } },
    orderBy: { createdAt: 'desc' },
    select: { createdAt: true },
  });
  if (recent) {
    const elapsed = Date.now() - recent.createdAt.getTime();
    if (elapsed < RESEND_COOLDOWN_MS) {
      return { code: null, cooldown: Math.ceil((RESEND_COOLDOWN_MS - elapsed) / 1000) };
    }
  }

  await prisma.otp.updateMany({
    where: { phone, consumed: false },
    data: { consumed: true },
  });

  const code = generateCode();
  await prisma.otp.create({
    data: {
      phone,
      code: hashCode(phone, code),
      expiresAt: new Date(Date.now() + OTP_TTL_MS),
    },
  });

  // Send whenever Twilio is configured, even in dev — otherwise you can never
  // exercise real delivery locally. Dev mode only controls whether the code is
  // *also* echoed back for the simulator to prefill.
  if (smsConfigured()) {
    await sendSms(phone, `Votre code Mobly est ${code}. Il expire dans 5 minutes.`);
  }

  if (env.otpDevMode) {
    // Dev only. A code must never reach production logs, support tooling or
    // analytics — same handling rules as a password.
    console.log(`[otp] ${phone} -> ${code}`);
    return { code };
  }

  // The "no provider" case is handled up front now, before any row is written.
  return { code: null };
}

/**
 * Check a code. Failures are counted on the stored record and the code is
 * burned once `MAX_ATTEMPTS` is reached — this is the per-phone half of the
 * brute-force defence, since an IP limiter alone won't stop an attacker
 * rotating addresses against a single number.
 */
export async function verifyOtp(phone: string, code: string): Promise<OtpVerifyResult> {
  const otp = await prisma.otp.findFirst({
    where: { phone, consumed: false },
    orderBy: { createdAt: 'desc' },
  });
  if (!otp) return 'invalid';

  if (otp.expiresAt <= new Date()) {
    await prisma.otp.update({ where: { id: otp.id }, data: { consumed: true } });
    return 'expired';
  }

  if (otp.attempts >= MAX_ATTEMPTS) {
    await prisma.otp.update({ where: { id: otp.id }, data: { consumed: true } });
    return 'locked';
  }

  if (!constantTimeEquals(otp.code, hashCode(phone, code))) {
    const attempts = otp.attempts + 1;
    await prisma.otp.update({
      where: { id: otp.id },
      // Burn the code on the final failure so it can't be retried.
      data: { attempts, consumed: attempts >= MAX_ATTEMPTS },
    });
    return attempts >= MAX_ATTEMPTS ? 'locked' : 'invalid';
  }

  // Single use — consume before returning so a replay can't reuse it.
  await prisma.otp.update({ where: { id: otp.id }, data: { consumed: true } });
  return 'ok';
}

/** Drop expired/consumed rows. Safe to call periodically. */
export async function pruneOtps(): Promise<number> {
  const { count } = await prisma.otp.deleteMany({
    where: { OR: [{ expiresAt: { lt: new Date() } }, { consumed: true }] },
  });
  return count;
}


