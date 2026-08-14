import rateLimit, { type Options } from 'express-rate-limit';
import type { Request, Response, NextFunction } from 'express';
import { randomUUID } from 'node:crypto';
import { env } from '../config/env';

/**
 * Rate limiters.
 *
 * Two tiers, per current Express guidance: a broad ceiling on everything, and
 * a much tighter one on anything that authenticates or costs money to send.
 * The OTP endpoints are the sharp edge here — a 6-digit code has ~20 bits of
 * entropy, so without a cap on verification attempts it falls to a trivial
 * brute force. NIST 800-63B wants online guessing capped well before 100
 * consecutive failures; `otpVerifyLimiter` is the IP-level half of that and
 * `services/otp.ts` enforces the per-phone half.
 *
 * NOTE: this store is in-process. Running more than one instance means each
 * gets its own counters — move to `rate-limit-redis` before scaling out.
 */

const common: Partial<Options> = {
  standardHeaders: 'draft-7', // RateLimit-* response headers
  legacyHeaders: false,
  // Rate-limit rejections are expected traffic, not crashes: answer in the
  // same {error} shape the app already parses.
  handler: (_req, res) => {
    res.status(429).json({
      error: 'Trop de tentatives. Réessayez dans quelques minutes.',
      code: 'RATE_LIMITED',
    });
  },
};

/** Broad ceiling on the whole API. */
export const globalLimiter = rateLimit({
  ...common,
  windowMs: 15 * 60 * 1000,
  limit: 300,
  // Health checks shouldn't burn budget.
  skip: (req) => req.path === '/health',
});

/** Anything that creates a session. */
export const authLimiter = rateLimit({
  ...common,
  windowMs: 15 * 60 * 1000,
  limit: 20,
});

/** Sending an SMS costs money — keep this tight per IP. */
export const otpRequestLimiter = rateLimit({
  ...common,
  windowMs: 15 * 60 * 1000,
  limit: 5,
  handler: (_req, res) => {
    res.status(429).json({
      error: 'Trop de demandes de code. Patientez quelques minutes.',
      code: 'OTP_RATE_LIMITED',
    });
  },
});

/**
 * Signup/SMS sends, counting **only requests that actually dispatched a code**.
 *
 * `/signup/start` validates the form and rejects duplicates before sending, so
 * without `skipFailedRequests` a handful of typos would exhaust the budget for
 * everyone sharing that IP — and carrier NAT means a lot of users share one.
 * Per-phone caps in `services/otp.ts` are the real control on SMS cost; this
 * just stops one address hammering the endpoint.
 */
export const smsSendLimiter = rateLimit({
  ...common,
  windowMs: 15 * 60 * 1000,
  limit: 10,
  skipFailedRequests: true, // 4xx/5xx don't consume the budget
  handler: (_req, res) => {
    res.status(429).json({
      error: 'Trop de codes envoyés. Patientez quelques minutes.',
      code: 'OTP_RATE_LIMITED',
    });
  },
});

/** Guessing a code. Deliberately the tightest limit in the app. */
export const otpVerifyLimiter = rateLimit({
  ...common,
  windowMs: 15 * 60 * 1000,
  limit: 10,
  handler: (_req, res) => {
    res.status(429).json({
      error: 'Trop de tentatives. Demandez un nouveau code.',
      code: 'OTP_RATE_LIMITED',
    });
  },
});

/** Writes are cheap to make and expensive to clean up. */
export const writeLimiter = rateLimit({
  ...common,
  windowMs: 15 * 60 * 1000,
  limit: 60,
});

/**
 * Attach a request id and echo it back. Makes a user-reported failure
 * traceable to a specific log line — without it, "it failed" is unactionable.
 */
export function requestId(req: Request, res: Response, next: NextFunction) {
  const incoming = req.headers['x-request-id'];
  const id = (typeof incoming === 'string' && incoming) || randomUUID();
  req.id = id;
  res.setHeader('X-Request-Id', id);
  next();
}

/**
 * Resolve the CORS origin. `origin: true` reflects whatever Origin the caller
 * sent, which combined with `credentials: true` means any site can make
 * credentialed calls — so it's allowed in dev only.
 */
export function corsOrigin(): boolean | string[] {
  const list = env.corsOrigins;
  if (list.includes('*')) {
    if (env.isProd) {
      throw new Error(
        'CORS_ORIGINS="*" is not allowed in production — set an explicit origin list.'
      );
    }
    return true;
  }
  return list;
}

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Express {
    interface Request {
      id?: string;
    }
  }
}
