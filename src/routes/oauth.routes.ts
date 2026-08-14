import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../lib/prisma';
import { asyncHandler, ApiError } from '../lib/http';
import { signToken } from '../lib/jwt';
import { issueRefreshToken } from '../services/refresh';
import { serializeUser } from '../lib/serialize';
import { authLimiter } from '../middleware/security';
import { verifyAppleIdentityToken } from '../lib/apple';
import { verifyGoogleIdentityToken } from '../lib/google';

export const oauthRouter = Router();

/**
 * POST /api/auth/apple — Sign in with Apple.
 *
 * Body: `{ idToken, fullName?, nonce? }`. The client sends the JWS Apple
 * returned to `ASAuthorizationController`; the server verifies it against
 * Apple's JWKS, looks up (or creates) an OAuthIdentity + User, and returns
 * the same `{token, refreshToken, user}` shape as the OTP verify path.
 *
 * `fullName` is populated only on the *first* Apple sign-in — subsequent
 * sign-ins receive nothing, so the client sends it once and we persist it.
 */
oauthRouter.post(
  '/apple',
  authLimiter,
  asyncHandler(async (req, res) => {
    const parsed = z
      .object({
        idToken: z.string().min(20),
        fullName: z.string().min(1).max(120).optional(),
        // Passed through so the server-side log can correlate — the verify
        // itself does not check nonce (that's a client-side concern).
        nonce: z.string().optional(),
      })
      .safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');

    let claims;
    try {
      claims = await verifyAppleIdentityToken(parsed.data.idToken);
    } catch {
      // Any failure — bad signature, wrong audience, expired — is a generic
      // 401 so we don't leak which check tripped.
      throw new ApiError(401, 'Jeton Apple invalide', 'UNAUTHENTICATED');
    }

    // Look up existing linkage.
    const link = await prisma.oAuthIdentity.findUnique({
      where: { provider_providerSub: { provider: 'apple', providerSub: claims.sub } },
      include: { user: true },
    });

    let user;
    if (link) {
      user = link.user;
      // Backfill an email we didn't have before.
      if (!user.email && claims.email) {
        user = await prisma.user.update({
          where: { id: user.id },
          data: { email: claims.email },
        });
      }
    } else {
      // Existing account with the same email? Link the identity to it instead
      // of creating a duplicate — this lets an OTP-signed-up user later add
      // Apple as another sign-in method without ending up with two accounts.
      const existingByEmail = claims.email
        ? await prisma.user.findUnique({ where: { email: claims.email } })
        : null;

      user = existingByEmail
        ?? (await prisma.user.create({
              data: {
                // We don't have a real phone for Apple sign-ins. Store a
                // deterministic placeholder that survives the phone unique
                // index; the user can set a real one later from the profile.
                phone: `apple:${claims.sub}`,
                fullName: parsed.data.fullName ?? 'Utilisateur Mobly',
                email: claims.email ?? null,
                verified: claims.email_verified ?? true,
                isOwner: false,
              },
            }));

      await prisma.oAuthIdentity.create({
        data: {
          userId: user.id,
          provider: 'apple',
          providerSub: claims.sub,
          email: claims.email ?? null,
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

/**
 * POST /api/auth/google — Sign in with Google.
 *
 * Body: `{ idToken }`. Same flow as Apple: verify JWT against Google's JWKS,
 * look up (or create) an OAuthIdentity + User, and return our token pair.
 */
oauthRouter.post(
  '/google',
  authLimiter,
  asyncHandler(async (req, res) => {
    const parsed = z.object({ idToken: z.string().min(20) }).safeParse(req.body);
    if (!parsed.success) throw new ApiError(400, 'Données invalides', 'VALIDATION_FAILED');

    let claims;
    try {
      claims = await verifyGoogleIdentityToken(parsed.data.idToken);
    } catch {
      throw new ApiError(401, 'Jeton Google invalide', 'UNAUTHENTICATED');
    }

    const link = await prisma.oAuthIdentity.findUnique({
      where: { provider_providerSub: { provider: 'google', providerSub: claims.sub } },
      include: { user: true },
    });

    let user;
    if (link) {
      user = link.user;
      if (!user.email && claims.email) {
        user = await prisma.user.update({
          where: { id: user.id },
          data: { email: claims.email },
        });
      }
    } else {
      const existingByEmail = claims.email
        ? await prisma.user.findUnique({ where: { email: claims.email } })
        : null;

      user = existingByEmail
        ?? (await prisma.user.create({
              data: {
                phone: `google:${claims.sub}`,
                fullName: claims.name ?? 'Utilisateur Mobly',
                email: claims.email ?? null,
                avatarUrl: claims.picture ?? null,
                verified: claims.email_verified ?? true,
                isOwner: false,
              },
            }));

      await prisma.oAuthIdentity.create({
        data: {
          userId: user.id,
          provider: 'google',
          providerSub: claims.sub,
          email: claims.email ?? null,
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
