import twilio, { Twilio } from 'twilio';
import { ApiError } from '../lib/http';
import { env } from '../config/env';

/**
 * SMS delivery via Twilio.
 *
 * Deliberately Programmable Messaging rather than Twilio Verify: the OTP
 * lifecycle (generation, hashing, attempt caps, per-phone volume limits) is
 * already implemented in `services/otp.ts` and tuned for the 4-digit code, so
 * handing that to Verify would mean two systems disagreeing about the rules.
 * Twilio's job here is transport only.
 */

let client: Twilio | null = null;

function getClient(): Twilio | null {
  if (!env.twilio.configured) return null;
  if (!client) {
    const { accountSid, authToken, apiKeySid, apiKeySecret } = env.twilio;
    client = apiKeySid && apiKeySecret
      // API Key auth: the key is passed as the username and the account SID
      // supplied separately, so the key can be revoked without touching the
      // account-wide Auth Token.
      ? twilio(apiKeySid, apiKeySecret, { accountSid })
      : twilio(accountSid, authToken);
  }
  return client;
}

export function smsConfigured(): boolean {
  return env.twilio.configured;
}

/**
 * Is this destination allowed?
 *
 * With a worldwide country picker in the app, every country becomes a possible
 * destination — which is exactly what SMS pumping abuses: an attacker drives
 * verification traffic to premium-rate ranges in a country you don't serve and
 * takes a cut of the carrier revenue while you pay for the messages. Twilio's
 * own guidance is to keep permissions off for countries with no business
 * interest, so this allowlist is enforced before a message is ever sent.
 *
 * `SMS_ALLOWED_COUNTRIES` holds E.164 dial prefixes (no `+`), longest match
 * wins. An empty list means "allow everything" and is only sane in dev.
 */
export function isAllowedDestination(e164: string): boolean {
  const allowed = env.twilio.allowedPrefixes;
  if (allowed.length === 0) return true;
  const digits = e164.replace(/^\+/, '');
  return allowed.some((prefix) => digits.startsWith(prefix));
}

/**
 * Twilio error codes worth translating rather than surfacing as a 500.
 * Full list: https://www.twilio.com/docs/api/errors
 */
const TWILIO_USER_ERRORS: Record<number, string> = {
  21211: 'Numéro de téléphone invalide',
  21214: 'Numéro de téléphone invalide',
  21408: 'Envoi non autorisé vers ce pays',
  21606: 'Numéro d’envoi indisponible. Contactez le support.',
  21610: 'Ce numéro s’est désabonné des SMS Mobly',
  21612: 'Impossible d’envoyer un SMS à ce numéro',
  21614: 'Ce numéro ne peut pas recevoir de SMS',
  30006: 'Numéro injoignable ou ligne fixe',
};

const TWILIO_STATUS_ERRORS: Record<number, string> = {
  403: 'SMS refusé par Twilio. Vérifiez les permissions pays, le sender ID et le numéro destinataire.',
};

function phoneFieldError(message: string): ApiError {
  const err = new ApiError(422, message, 'VALIDATION_FAILED');
  (err as ApiError & { fields?: Record<string, string> }).fields = { phone: message };
  return err;
}

export interface SmsResult {
  delivered: boolean;
  /** Twilio message SID, for correlating with their console. */
  sid?: string;
}

/**
 * Send one SMS. Throws ApiError for problems the user can act on; anything
 * else propagates so it's logged as a real fault.
 */
export async function sendSms(to: string, body: string): Promise<SmsResult> {
  if (!isAllowedDestination(to)) {
    throw new ApiError(
      403,
      'Envoi de SMS non disponible vers ce pays pour le moment',
      'FORBIDDEN'
    );
  }

  const c = getClient();
  if (!c) {
    // No credentials: in dev the code is returned in the response instead, so
    // this is expected. In production it means nobody receives anything —
    // make that loud rather than silently succeeding.
    if (env.isProd) {
      console.error('[sms] Twilio is not configured — no message sent to', to);
      throw new ApiError(503, 'Service SMS indisponible', 'INTERNAL');
    }
    console.warn(`[sms] Twilio not configured (dev) — would send to ${to}`);
    return { delivered: false };
  }

  try {
    const message = await c.messages.create({
      to,
      body,
      // A Messaging Service handles sender selection, opt-outs and
      // deliverability far better than a single from-number, so prefer it.
      ...(env.twilio.messagingServiceSid
        ? { messagingServiceSid: env.twilio.messagingServiceSid }
        : { from: env.twilio.fromNumber }),
    });
    return { delivered: true, sid: message.sid };
  } catch (err) {
    const code = (err as { code?: number }).code;
    const status = (err as { status?: number }).status;
    if (code && TWILIO_USER_ERRORS[code]) {
      throw phoneFieldError(TWILIO_USER_ERRORS[code]);
    }
    if (status && TWILIO_STATUS_ERRORS[status]) {
      throw phoneFieldError(TWILIO_STATUS_ERRORS[status]);
    }
    // Log the real reason, return something generic — Twilio errors can carry
    // account identifiers we don't want in a client response.
    console.error('[sms] send failed', {
      to,
      code,
      status,
      message: err instanceof Error ? err.message : String(err),
      moreInfo: (err as { moreInfo?: string }).moreInfo,
      details: (err as { details?: unknown }).details,
    });
    throw new ApiError(502, 'Envoi du SMS impossible. Réessayez.', 'INTERNAL');
  }
}
