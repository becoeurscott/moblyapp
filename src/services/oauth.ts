import { createRemoteJWKSet, jwtVerify, SignJWT, jwtVerify as verifyLocal } from 'jose';
import { ApiError } from '../lib/http';
import { env } from '../config/env';

/**
 * Google / Apple sign-in.
 *
 * The client performs the native sign-in and hands us the provider's ID token.
 * We verify that token's signature against the provider's published keys —
 * never trust the email or user id the app claims, since anything can POST a
 * hand-written JSON body. The signature is the entire security boundary.
 */

const GOOGLE_JWKS = createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs'));
const APPLE_JWKS = createRemoteJWKSet(new URL('https://appleid.apple.com/auth/keys'));

export type OAuthProvider = 'google' | 'apple';

export interface OAuthIdentity {
  provider: OAuthProvider;
  /** Provider's stable user id (`sub`). */
  subject: string;
  email: string;
  emailVerified: boolean;
  fullName?: string;
}

/**
 * Verify a provider ID token and extract the identity.
 * Throws ApiError(401) on anything that doesn't check out.
 */
export async function verifyOAuthToken(
  provider: OAuthProvider,
  idToken: string,
  /** Name from the native SDK — Apple only returns it on first authorization. */
  fallbackName?: string
): Promise<OAuthIdentity> {
  const audience = provider === 'google' ? env.oauth.googleClientIds : env.oauth.appleBundleIds;
  if (audience.length === 0) {
    throw new ApiError(
      503,
      'Connexion via ce service indisponible',
      'INTERNAL'
    );
  }

  try {
    const { payload } = await jwtVerify(
      idToken,
      provider === 'google' ? GOOGLE_JWKS : APPLE_JWKS,
      {
        // Pinning issuer and audience is what stops a token minted for a
        // *different* app being replayed against ours.
        issuer:
          provider === 'google'
            ? ['https://accounts.google.com', 'accounts.google.com']
            : 'https://appleid.apple.com',
        audience,
      }
    );

    const email = typeof payload.email === 'string' ? payload.email.toLowerCase() : '';
    if (!email) {
      throw new ApiError(401, 'Ce compte ne fournit pas d’adresse e-mail', 'UNAUTHENTICATED');
    }

    // Google uses a boolean, Apple sends the string "true".
    const verifiedClaim = payload.email_verified;
    const emailVerified = verifiedClaim === true || verifiedClaim === 'true';

    const name =
      (typeof payload.name === 'string' && payload.name) ||
      fallbackName ||
      undefined;

    return {
      provider,
      subject: String(payload.sub),
      email,
      emailVerified,
      fullName: name,
    };
  } catch (err) {
    if (err instanceof ApiError) throw err;
    throw new ApiError(401, 'Connexion refusée par le fournisseur', 'UNAUTHENTICATED');
  }
}

/**
 * Short-lived token representing "this person proved an email, but we still
 * need their phone".
 *
 * No database row is created until the phone is verified — a `User` requires a
 * unique phone, and inventing a placeholder would leave half-built accounts
 * that collide with real signups later. This token carries the verified
 * identity for the ten minutes the phone step should take.
 *
 * `purpose` is checked on the way back in so a pending token can never be used
 * as an access token.
 */
const PENDING_PURPOSE = 'pending_signup';
const PENDING_TTL = '10m';

export interface PendingSignup {
  email: string;
  fullName?: string;
  provider: OAuthProvider;
  subject: string;
}

export async function issuePendingSignupToken(identity: OAuthIdentity): Promise<string> {
  const secret = new TextEncoder().encode(env.jwtSecret);
  return new SignJWT({
    purpose: PENDING_PURPOSE,
    email: identity.email,
    fullName: identity.fullName,
    provider: identity.provider,
    subject: identity.subject,
  })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime(PENDING_TTL)
    .sign(secret);
}

export async function readPendingSignupToken(token: string): Promise<PendingSignup> {
  try {
    const secret = new TextEncoder().encode(env.jwtSecret);
    const { payload } = await verifyLocal(token, secret);
    if (payload.purpose !== PENDING_PURPOSE) {
      throw new ApiError(401, 'Session d’inscription invalide', 'UNAUTHENTICATED');
    }
    return {
      email: String(payload.email),
      fullName: payload.fullName ? String(payload.fullName) : undefined,
      provider: payload.provider as OAuthProvider,
      subject: String(payload.subject),
    };
  } catch (err) {
    if (err instanceof ApiError) throw err;
    throw new ApiError(
      401,
      'Session d’inscription expirée. Recommencez.',
      'UNAUTHENTICATED'
    );
  }
}


/**
 * Short-lived token binding a password-reset attempt to one account.
 *
 * The reset flow must be able to say *where* the code went without handing the
 * caller the actual number — otherwise anyone holding an e-mail address could
 * harvest the phone behind it, one request at a time. The real phone travels
 * inside this signed token; the client only ever sees a masked version.
 */
const RESET_PURPOSE = 'password_reset';
const RESET_TTL = '15m';

export async function issueResetToken(userId: string, phone: string): Promise<string> {
  const secret = new TextEncoder().encode(env.jwtSecret);
  return new SignJWT({ purpose: RESET_PURPOSE, sub: userId, phone })
    .setProtectedHeader({ alg: 'HS256' })
    .setIssuedAt()
    .setExpirationTime(RESET_TTL)
    .sign(secret);
}

export async function readResetToken(token: string): Promise<{ userId: string; phone: string }> {
  try {
    const secret = new TextEncoder().encode(env.jwtSecret);
    const { payload } = await verifyLocal(token, secret);
    if (payload.purpose !== RESET_PURPOSE) {
      throw new ApiError(401, 'Session de réinitialisation invalide', 'UNAUTHENTICATED');
    }
    return { userId: String(payload.sub), phone: String(payload.phone) };
  } catch (err) {
    if (err instanceof ApiError) throw err;
    throw new ApiError(
      401,
      'Session de réinitialisation expirée. Recommencez.',
      'UNAUTHENTICATED'
    );
  }
}

/** "+237699887766" -> "+237 6•• •• •• 66" — enough to recognise, not to dial. */
export function maskPhone(e164: string): string {
  const digits = e164.replace(/\D/g, '');
  if (digits.length < 6) return '•••';
  const cc = e164.startsWith('+') ? e164.slice(0, e164.length - digits.length + 3) : '';
  const last2 = digits.slice(-2);
  const first1 = digits.slice(cc.replace('+', '').length, cc.replace('+', '').length + 1);
  return `${cc} ${first1}•• •• •• ${last2}`.trim();
}
