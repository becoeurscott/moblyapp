import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { requireAuth } from '../middleware/auth';
import { authLimiter, otpVerifyLimiter } from '../middleware/security';
import { serializeUser } from '../lib/serialize';
import { maskEmail } from '../services/email';
import {
  sendEmailCode,
  checkEmailCode,
  emailCodeError,
  EMAIL_CODE_LENGTH,
} from '../services/emailCode';

export const emailRouter = Router();

/**
 * E-mail confirmation, in two calls (signed-in user):
 *   1. POST /auth/email/send   — mail a code to the account address, or to a
 *                                new address the user wants to switch to
 *   2. POST /auth/email/verify — check it; the address it went to becomes the
 *                                account's confirmed e-mail
 *
 * A new address is only written to the account once its code checks out, so a
 * typo can never replace a working address.
 */
emailRouter.post(
  '/send',
  requireAuth,
  authLimiter,
  asyncHandler(async (req, res) => {
    const body = z
      .object({ email: z.string().trim().email('Adresse e-mail invalide').optional() })
      .parse(req.body ?? {});

    const user = await prisma.user.findUnique({ where: { id: req.userId! } });
    if (!user) throw new ApiError(401, 'Connexion requise', 'UNAUTHENTICATED');

    const target = (body.email ?? user.email ?? '').trim().toLowerCase();
    if (!target) {
      const err = new ApiError(422, 'Ajoutez une adresse e-mail', 'VALIDATION_FAILED');
      (err as ApiError & { fields?: Record<string, string> }).fields = { email: 'Adresse e-mail requise' };
      throw err;
    }

    if (target === user.email && user.emailVerifiedAt) {
      res.json({ sent: false, alreadyVerified: true, email: target, user: serializeUser(user) });
      return;
    }

    if (target !== user.email) {
      const taken = await prisma.user.findFirst({
        where: { email: target, NOT: { id: user.id } },
        select: { id: true },
      });
      if (taken) {
        const err = new ApiError(409, 'Cet e-mail est déjà utilisé par un autre compte', 'ALREADY_EXISTS');
        (err as ApiError & { fields?: Record<string, string> }).fields = { email: 'Cet e-mail est déjà utilisé' };
        throw err;
      }
    }

    const { devCode } = await sendEmailCode(user.id, target, 'verify');
    res.json({
      sent: true,
      email: target,
      maskedEmail: maskEmail(target),
      codeLength: EMAIL_CODE_LENGTH,
      devCode,
    });
  })
);

emailRouter.post(
  '/verify',
  requireAuth,
  otpVerifyLimiter,
  asyncHandler(async (req, res) => {
    const { code } = z.object({ code: z.string().trim().length(EMAIL_CODE_LENGTH) }).parse(req.body);

    const { result, email } = await checkEmailCode(req.userId!, 'verify', code);
    if (result !== 'ok') throw emailCodeError(result);

    // Someone could have claimed the address while the code was in flight.
    const taken = await prisma.user.findFirst({
      where: { email, NOT: { id: req.userId! } },
      select: { id: true },
    });
    if (taken) {
      throw new ApiError(409, 'Cet e-mail est déjà utilisé par un autre compte', 'ALREADY_EXISTS');
    }

    const user = await prisma.user.update({
      where: { id: req.userId! },
      data: { email, emailVerifiedAt: new Date() },
    });
    res.json({ user: serializeUser(user) });
  })
);
