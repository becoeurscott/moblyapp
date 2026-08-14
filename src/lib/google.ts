/**
 * Sign in with Google — identity-token verification.
 *
 * Google returns an RS256-signed JWT, keyed by their rotating JWKS at
 * https://www.googleapis.com/oauth2/v3/certs. We fetch that JWKS (cached for
 * 10 minutes by jose's remote-key cache) and verify:
 *   • signature against Google's public key
 *   • `iss` is `https://accounts.google.com` or `accounts.google.com`
 *   • `aud` = our Google iOS OAuth client id (`GOOGLE_CLIENT_ID` env)
 *   • `exp` in the future
 */
import { createRemoteJWKSet, jwtVerify } from 'jose';

const GOOGLE_JWKS_URL = new URL('https://www.googleapis.com/oauth2/v3/certs');
const GOOGLE_ISSUERS = new Set(['https://accounts.google.com', 'accounts.google.com']);

const googleJWKS = createRemoteJWKSet(GOOGLE_JWKS_URL, {
  cacheMaxAge: 10 * 60 * 1000,
  cooldownDuration: 30_000,
});

export interface GoogleIdentityClaims {
  sub: string;                // stable Google user id
  email?: string;
  email_verified?: boolean;
  name?: string;
  picture?: string;
}

/**
 * Verify a Google ID token. Throws on any failure — invalid signature, wrong
 * audience, wrong issuer, expired, etc.
 */
export async function verifyGoogleIdentityToken(idToken: string): Promise<GoogleIdentityClaims> {
  const audience = process.env.GOOGLE_CLIENT_ID?.split(',').map((s) => s.trim()).filter(Boolean);
  if (!audience || audience.length === 0) {
    throw new Error('GOOGLE_CLIENT_ID env is not set');
  }

  // Google issues tokens from two subtly different issuers. jose accepts an
  // issuer array, so both variants pass.
  const { payload } = await jwtVerify(idToken, googleJWKS, {
    issuer: [...GOOGLE_ISSUERS],
    audience,
  });

  if (typeof payload.sub !== 'string' || payload.sub.length === 0) {
    throw new Error('Google token missing subject');
  }

  return {
    sub: payload.sub,
    email: typeof payload.email === 'string' ? payload.email : undefined,
    email_verified: payload.email_verified === true || payload.email_verified === 'true',
    name: typeof payload.name === 'string' ? payload.name : undefined,
    picture: typeof payload.picture === 'string' ? payload.picture : undefined,
  };
}
