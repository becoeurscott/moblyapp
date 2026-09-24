import { ApiError } from '../lib/http';
import { env } from '../config/env';
import { isAllowedDestination } from './sms';
import { getTwilioClient, twilioConfigured } from './twilio-client';
import type { OtpVerifyResult } from './otp';

export function verifyConfigured(): boolean {
  return twilioConfigured() && Boolean(env.twilio.verifyServiceSid);
}

function service() {
  const client = getTwilioClient();
  if (!client || !env.twilio.verifyServiceSid) return null;
  return client.verify.v2.services(env.twilio.verifyServiceSid);
}

function phoneFieldError(message: string): ApiError {
  const err = new ApiError(422, message, 'VALIDATION_FAILED');
  (err as ApiError & { fields?: Record<string, string> }).fields = { phone: message };
  return err;
}

export async function startVerify(phone: string): Promise<void> {
  if (!isAllowedDestination(phone)) {
    throw new ApiError(
      403,
      'Envoi de SMS non disponible vers ce pays pour le moment',
      'FORBIDDEN'
    );
  }
  const s = service();
  if (!s) throw new ApiError(503, 'Service SMS indisponible', 'INTERNAL');

  try {
    const verification = await s.verifications.create({ to: phone, channel: 'sms' });
    console.info('[verify] started', {
      to: phone.replace(/(\+\d{3})\d+(\d{2})$/, '$1…$2'),
      sid: verification.sid,
      status: verification.status,
    });
  } catch (err) {
    const code = (err as { code?: number }).code;
    const status = (err as { status?: number }).status;
    console.error('[verify] start failed', {
      code,
      status,
      message: err instanceof Error ? err.message : String(err),
      moreInfo: (err as { moreInfo?: string }).moreInfo,
    });
    // 60203 is Twilio's own "max send attempts reached" for this number's
    // pending verification. Nothing is wrong with the number, so the old
    // message sent people off to re-type a phone that was already correct —
    // and re-typing it triggered another send, which is what exhausted the
    // budget in the first place. The only remedy is to let the verification
    // expire, so say that instead.
    if (code === 60203) {
      throw new ApiError(
        429,
        'Trop de demandes de code pour ce numéro. Patientez 10 minutes avant de réessayer.',
        'OTP_RATE_LIMITED'
      );
    }
    throw phoneFieldError('Envoi du code impossible. Vérifiez le numéro et réessayez.');
  }
}

export async function checkVerify(phone: string, code: string): Promise<OtpVerifyResult> {
  const s = service();
  if (!s) return 'invalid';
  try {
    const check = await s.verificationChecks.create({ to: phone, code });
    return check.status === 'approved' ? 'ok' : 'invalid';
  } catch (err) {
    const twilioCode = (err as { code?: number }).code;
    // 20404 covers three states Twilio doesn't distinguish: the code expired,
    // it was already approved, or there is no pending verification for this
    // number at all. "Expired" is the right advice for all three — the user
    // needs a fresh code either way — but it is not literally accurate, so
    // don't read this as proof that the code timed out.
    if (twilioCode === 20404) return 'expired';
    console.error('[verify] check failed', {
      code: twilioCode,
      status: (err as { status?: number }).status,
      message: err instanceof Error ? err.message : String(err),
    });
    return 'invalid';
  }
}
