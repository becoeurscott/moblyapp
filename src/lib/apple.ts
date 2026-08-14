/**
 * Sign in with Apple — identity-token verification.
 *
 * Apple returns a compact JWS signed with ES256, keyed by their rotating JWKS
 * at https://appleid.apple.com/auth/keys. We fetch that JWKS (cached for 10
 * minutes by jose's built-in remote-key cache) and verify:
 *   • signature against Apple's public key
 *   • `iss` = https://appleid.apple.com
 *   • `aud` = our iOS bundle id (`APPLE_AUDIENCE` env, e.g. cm.mobly.app)
 *   • `exp` in the future
 *
 * We do NOT verify `nonce` here — that belongs on the client and is only
 * needed if we implement replay protection later.
 */
import { createRemoteJWKSet, jwtVerify } from 'jose';

const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_JWKS_URL = new URL('https://appleid.apple.com/auth/keys');

// One shared JWKS instance so we don't refetch on every request. `jose`
// handles caching + rotation.
const appleJWKS = createRemoteJWKSet(APPLE_JWKS_URL, {
  cacheMaxAge: 10 * 60 * 1000,
  cooldownDuration: 30_000,
});

export interface AppleIdentityClaims {
  sub: string;                // stable, per-app user id
  email?: string;             // may be Apple's private-relay address
  email_verified?: boolean;
  is_private_email?: boolean;
}

/**
 * Verify an Apple identity token. Throws on any failure — invalid signature,
 * wrong audience, wrong issuer, expired, etc. The caller catches once and
 * returns a generic 401 so we don't leak which of the checks failed.
 */
export async function verifyAppleIdentityToken(idToken: string): Promise<AppleIdentityClaims> {
  const audience = process.env.APPLE_AUDIENCE?.split(',').map((s) => s.trim()).filter(Boolean);
  if (!audience || audience.length === 0) {
    throw new Error('APPLE_AUDIENCE env is not set — configure the app bundle id (e.g. cm.mobly.app)');
  }
  const { payload } = await jwtVerify(idToken, appleJWKS, {
    issuer: APPLE_ISSUER,
    audience,
  });
  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Apple token missing subject');
  }
  return {
    sub: payload.sub,
    email: typeof payload.email === 'string' ? payload.email : undefined,
    email_verified: payload.email_verified === true || payload.email_verified === 'true',
    is_private_email: payload.is_private_email === true || payload.is_private_email === 'true',
  };
}
