import { Router } from 'express';
import { z } from 'zod';
import bcrypt from 'bcryptjs';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { signToken } from '../lib/jwt';
import { createOtp, verifyOtp, otpLength } from '../services/otp';
import { issueRefreshToken } from '../services/refresh';
import { checkPassword, PASSWORD_RULE_MESSAGES } from '../lib/password';
import { serializeUser } from '../lib/serialize';
import {
  authLimiter,
  smsSendLimiter,
  otpVerifyLimiter,
} from '../middleware/security';
import {
  verifyOAuthToken,
  issuePendingSignupToken,
  readPendingSignupToken,
  type OAuthProvider,
} from '../services/oauth';

export const signupRouter = Router();

/**
 * Signup is two calls:
 *   1. POST /signup/start  — validate everything, reject duplicates, send a code
 *   2. POST /signup/verify — check the code, create the account
 *
 * Splitting it means a user never receives an SMS for a signup that was going
 * to fail anyway (duplicate email, weak password), and every field error is
 * reported before the phone step rather than after it.
 */

/** E.164, defaulting to Cameroon. Mirrors AuthStore.normalizePhone on iOS. */
function normalizePhone(raw: string): string {
  let s = raw.replace(/[^\d+]/g, '');
  if (s.startsWith('+')) return s;
  if (s.startsWith('00')) return '+' + s.slice(2);
  if (s.startsWith('237')) return '+' + s;
  if (s.startsWith('0')) s = s.slice(1);
  return '+237' + s;
}

function normalizeEmail(raw: string): string {
  return raw.trim().toLowerCase();
}

const signupSchema = z.object({
  fullName: z.string().trim().min(2, 'Nom trop court').max(80),
  phone: z.string().min(6),
  email: z.string().trim().email('Adresse e-mail invalide'),
  password: z.string().min(1, 'Mot de passe requis'),
});

/**
 * Field-level errors keyed by field name, so the client can pin each message to
 * its own input instead of showing one banner for the whole form.
 */
type FieldErrors = Record<string, string>;

function fieldErrorsFrom(zodError: z.ZodError): FieldErrors {
  const out: FieldErrors = {};
  for (const issue of zodError.issues) {
    const key = String(issue.path[0] ?? 'form');
    if (!out[key]) out[key] = issue.message;
  }
  return out;
}

/** 422 carrying per-field messages. */
function validationError(fields: FieldErrors): never {
  const err = new ApiError(422, 'Vérifiez les informations saisies', 'VALIDATION_FAILED');
  (err as ApiError & { fields?: FieldErrors }).fields = fields;
  throw err;
}

/**
 * POST /auth/signup/start
 * Validates the whole form, refuses duplicates, then sends the code.
 */
signupRouter.post(
  '/start',
  smsSendLimiter,
  asyncHandler(async (req, res) => {
    const parsed = signupSchema.safeParse(req.body);
    if (!parsed.success) validationError(fieldErrorsFrom(parsed.error));

    const fullName = parsed.data.fullName;
    const phone = normalizePhone(parsed.data.phone);
    const email = normalizeEmail(parsed.data.email);

    const fields: FieldErrors = {};
    if (!/^\+\d{8,15}$/.test(phone)) fields.phone = 'Numéro de téléphone invalide';

    // Password rules run server-side too — client validation is a convenience,
    // not a control, and anything hitting the API directly skips it.
    const pw = checkPassword(parsed.data.password, [fullName, email, phone]);
    if (!pw.ok) {
      fields.password = pw.failed.map((r) => PASSWORD_RULE_MESSAGES[r]).join(' · ');
    }
    if (Object.keys(fields).length) validationError(fields);

    // Duplicate check before sending anything. Both columns are UNIQUE, so the
    // create would fail anyway — catching it here produces a message the user
    // can act on ("connectez-vous") instead of a constraint violation, and
    // avoids burning an SMS.
    const existing = await prisma.user.findFirst({
      where: { OR: [{ phone }, { email }] },
      select: { phone: true, email: true },
    });
    if (existing) {
      const takenPhone = existing.phone === phone;
      const err = new ApiError(
        409,
        takenPhone
          ? 'Un compte existe déjà avec ce numéro. Connectez-vous.'
          : 'Un compte existe déjà avec cet e-mail. Connectez-vous.',
        'ALREADY_EXISTS'
      );
      (err as ApiError & { fields?: FieldErrors }).fields = takenPhone
        ? { phone: 'Ce numéro est déjà utilisé' }
        : { email: 'Cet e-mail est déjà utilisé' };
      throw err;
    }

    const { code, cooldown, capped } = await createOtp(phone);
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

    res.json({ sent: true, phone, codeLength: otpLength(), devCode: code });
  })
);

/**
 * POST /auth/signup/verify
 * Confirms the code and creates the account.
 */
signupRouter.post(
  '/verify',
  otpVerifyLimiter,
  asyncHandler(async (req, res) => {
    const codeLength = otpLength();
    const schema = signupSchema.extend({
      code: z.string().length(codeLength, `Code à ${codeLength} chiffres`),
    });
    const parsed = schema.safeParse(req.body);
    if (!parsed.success) validationError(fieldErrorsFrom(parsed.error));

    const fullName = parsed.data.fullName;
    const phone = normalizePhone(parsed.data.phone);
    const email = normalizeEmail(parsed.data.email);

    const pw = checkPassword(parsed.data.password, [fullName, email, phone]);
    if (!pw.ok) {
      validationError({
        password: pw.failed.map((r) => PASSWORD_RULE_MESSAGES[r]).join(' · '),
      });
    }

    const result = await verifyOtp(phone, parsed.data.code);
    if (result !== 'ok') {
      const map = {
        invalid: [401, 'Code incorrect', 'OTP_INVALID'],
        expired: [401, 'Code expiré, demandez-en un nouveau', 'OTP_EXPIRED'],
        locked: [429, 'Trop de tentatives. Demandez un nouveau code.', 'OTP_LOCKED'],
      } as const;
      const [status, message, code] = map[result];
      throw new ApiError(status, message, code);
    }

    // Re-check: someone could have registered this phone or email between
    // /start and /verify. The unique indexes are the real guarantee, but this
    // turns the race into the same friendly 409 rather than a 500.
    const existing = await prisma.user.findFirst({
      where: { OR: [{ phone }, { email }] },
      select: { id: true },
    });
    if (existing) {
      throw new ApiError(
        409,
        'Un compte existe déjà avec ces informations. Connectez-vous.',
        'ALREADY_EXISTS'
      );
    }

    const user = await prisma.user.create({
      data: {
        phone,
        email,
        fullName,
        passwordHash: await bcrypt.hash(parsed.data.password, 10),
        // The OTP just proved they control the number.
        verified: true,
        verifiedAt: new Date(),
      },
    });

    const token = signToken({ sub: user.id, phone: user.phone });
    const refresh = await issueRefreshToken(user.id);
    res.status(201).json({
      token,
      refreshToken: refresh.token,
      refreshExpiresAt: refresh.expiresAt,
      user: serializeUser(user),
    });
  })
);

/**
 * POST /auth/signup/check — live availability check for the signup form.
 *
 * Lets the UI flag a taken email or number while the user is still typing,
 * instead of after they submit. Deliberately mirrors what /start would say.
 *
 * This does confirm whether an address is registered. That's a product
 * decision: the signup flow has to tell people an account exists so they can
 * sign in, and hiding it here while /start reveals it would buy nothing.
 */
/**
 * One character apart, ignoring case — "scottbecoer" vs "scottbecoeur".
 * Cheap Levenshtein bounded at 2, which is all we need to spot a typo.
 */
function nearlyEqual(a: string, b: string): boolean {
  if (a === b) return false;                 // identical is a duplicate, not a typo
  if (Math.abs(a.length - b.length) > 2) return false;
  const m = a.length;
  const n = b.length;
  const d: number[][] = Array.from({ length: m + 1 }, (_, i) =>
    Array.from({ length: n + 1 }, (_, j) => (i === 0 ? j : j === 0 ? i : 0))
  );
  for (let i = 1; i <= m; i++) {
    for (let j = 1; j <= n; j++) {
      d[i][j] = Math.min(
        d[i - 1][j] + 1,
        d[i][j - 1] + 1,
        d[i - 1][j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1)
      );
    }
  }
  return d[m][n] <= 2;
}

signupRouter.post(
  '/check',
  authLimiter,
  asyncHandler(async (req, res) => {
    const { phone, email } = z
      .object({ phone: z.string().optional(), email: z.string().optional() })
      .parse(req.body);

    const out: {
      phoneTaken?: boolean;
      emailTaken?: boolean;
      /** An existing address one or two characters away — probably a typo. */
      similarEmail?: string;
    } = {};

    if (phone) {
      const p = normalizePhone(phone);
      if (/^\+\d{8,15}$/.test(p)) {
        out.phoneTaken = Boolean(await prisma.user.findUnique({ where: { phone: p } }));
      }
    }
    if (email) {
      const e = normalizeEmail(email);
      if (z.string().email().safeParse(e).success) {
        out.emailTaken = Boolean(await prisma.user.findUnique({ where: { email: e } }));

        // Not taken, but within a character or two of an address that is —
        // almost certainly the same person mistyping, which otherwise creates
        // a second account and makes their history look lost.
        if (!out.emailTaken) {
          const [local, domain] = e.split('@');
          const sameDomain = await prisma.user.findMany({
            where: { email: { endsWith: `@${domain}` } },
            select: { email: true },
            take: 50,
          });
          const match = sameDomain.find(
            (u) => u.email && nearlyEqual(u.email.split('@')[0], local)
          );
          if (match?.email) {
            // Masked: confirming the exact address of another account would
            // hand out e-mails to anyone probing the endpoint.
            const [ml, md] = match.email.split('@');
            out.similarEmail = `${ml.slice(0, 2)}${'•'.repeat(Math.max(1, ml.length - 3))}${ml.slice(-1)}@${md}`;
          }
        }
      }
    }
    res.json(out);
  })
);

/**
 * POST /auth/oauth — exchange a Google/Apple ID token.
 *
 * Two outcomes:
 *   • the email already has an account → signed in, full tokens returned
 *   • it doesn't → `needsPhone: true` plus a 10-minute pending token; no user
 *     row exists yet, because a marketplace account without a reachable number
 *     isn't useful and `User.phone` is required + unique.
 */
signupRouter.post(
  '/oauth',
  authLimiter,
  asyncHandler(async (req, res) => {
    const { provider, idToken, fullName } = z
      .object({
        provider: z.enum(['google', 'apple']),
        idToken: z.string().min(20),
        fullName: z.string().trim().min(2).max(80).optional(),
      })
      .parse(req.body);

    const identity = await verifyOAuthToken(provider as OAuthProvider, idToken, fullName);

    // Apple lets users hide their real address behind a relay; both providers
    // can also return an unverified one. Either way we haven't proven the
    // address belongs to them, so it must not silently adopt an existing account.
    if (!identity.emailVerified) {
      throw new ApiError(
        401,
        'Adresse e-mail non vérifiée par le fournisseur',
        'UNAUTHENTICATED'
      );
    }

    const existing = await prisma.user.findUnique({ where: { email: identity.email } });
    if (existing) {
      const token = signToken({ sub: existing.id, phone: existing.phone });
      const refresh = await issueRefreshToken(existing.id);
      return res.json({
        needsPhone: false,
        token,
        refreshToken: refresh.token,
        refreshExpiresAt: refresh.expiresAt,
        user: serializeUser(existing),
      });
    }

    const pendingToken = await issuePendingSignupToken(identity);
    res.json({
      needsPhone: true,
      pendingToken,
      email: identity.email,
      fullName: identity.fullName ?? null,
      codeLength: otpLength(),
    });
  })
);

/**
 * POST /auth/signup/oauth/phone/start — send a code to the number a
 * Google/Apple user just entered. Authorised by the pending token, not a
 * session: there is no account yet.
 */
signupRouter.post(
  '/oauth/phone/start',
  smsSendLimiter,
  asyncHandler(async (req, res) => {
    const { pendingToken, phone: raw } = z
      .object({ pendingToken: z.string().min(20), phone: z.string().min(6) })
      .parse(req.body);

    await readPendingSignupToken(pendingToken); // throws if expired/forged
    const phone = normalizePhone(raw);
    if (!/^\+\d{8,15}$/.test(phone)) validationError({ phone: 'Numéro de téléphone invalide' });

    if (await prisma.user.findUnique({ where: { phone }, select: { id: true } })) {
      const err = new ApiError(
        409,
        'Un compte existe déjà avec ce numéro. Connectez-vous.',
        'ALREADY_EXISTS'
      );
      (err as ApiError & { fields?: FieldErrors }).fields = {
        phone: 'Ce numéro est déjà utilisé',
      };
      throw err;
    }

    const { code, cooldown, capped } = await createOtp(phone);
    if (capped) {
      throw new ApiError(429, 'Trop de codes demandés. Réessayez plus tard.', 'OTP_RATE_LIMITED');
    }
    if (cooldown) {
      throw new ApiError(
        429,
        `Patientez ${cooldown}s avant de redemander un code`,
        'OTP_RATE_LIMITED'
      );
    }
    res.json({ sent: true, phone, codeLength: otpLength(), devCode: code });
  })
);

/**
 * POST /auth/signup/oauth/phone/verify — confirm the code and finally create
 * the account, with the provider's verified email and the just-proven phone.
 */
signupRouter.post(
  '/oauth/phone/verify',
  otpVerifyLimiter,
  asyncHandler(async (req, res) => {
    const codeLength = otpLength();
    const { pendingToken, phone: raw, code, fullName } = z
      .object({
        pendingToken: z.string().min(20),
        phone: z.string().min(6),
        code: z.string().length(codeLength),
        fullName: z.string().trim().min(2).max(80).optional(),
      })
      .parse(req.body);

    const pending = await readPendingSignupToken(pendingToken);
    const phone = normalizePhone(raw);

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

    // Re-check both columns — another signup could have taken either since the
    // pending token was issued.
    const clash = await prisma.user.findFirst({
      where: { OR: [{ phone }, { email: pending.email }] },
      select: { id: true },
    });
    if (clash) {
      throw new ApiError(
        409,
        'Un compte existe déjà avec ces informations. Connectez-vous.',
        'ALREADY_EXISTS'
      );
    }

    const user = await prisma.user.create({
      data: {
        phone,
        email: pending.email,
        fullName: fullName ?? pending.fullName ?? 'Utilisateur Mobly',
        // No password: this account signs in through the provider. A password
        // can be added later from the profile screen.
        verified: true,
        verifiedAt: new Date(),
      },
    });

    const token = signToken({ sub: user.id, phone: user.phone });
    const refresh = await issueRefreshToken(user.id);
    res.status(201).json({
      token,
      refreshToken: refresh.token,
      refreshExpiresAt: refresh.expiresAt,
      user: serializeUser(user),
    });
  })
);
