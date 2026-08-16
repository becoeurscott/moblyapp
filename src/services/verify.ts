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
    if (twilioCode === 20404) return 'expired';
    console.error('[verify] check failed', {
      code: twilioCode,
      status: (err as { status?: number }).status,
      message: err instanceof Error ? err.message : String(err),
    });
    return 'invalid';
  }
}
