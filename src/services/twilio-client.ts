import twilio, { Twilio } from 'twilio';
import { ApiError } from '../lib/http';
import { env } from '../config/env';

let client: Twilio | null = null;

export function twilioConfigured(): boolean {
  return env.twilio.configured;
}

export function getTwilioClient(): Twilio | null {
  if (!twilioConfigured()) return null;
  if (!client) {
    const { accountSid, authToken, apiKeySid, apiKeySecret } = env.twilio;
    if (!accountSid.startsWith('AC')) {
      console.error('[twilio] invalid TWILIO_ACCOUNT_SID; expected AC... account SID');
      throw new ApiError(503, 'Configuration SMS invalide', 'INTERNAL');
    }
    if ((apiKeySid || apiKeySecret) && !apiKeySid.startsWith('SK')) {
      console.error('[twilio] invalid TWILIO_API_KEY_SID; expected SK... API Key SID');
      throw new ApiError(503, 'Configuration SMS invalide', 'INTERNAL');
    }
    client = apiKeySid && apiKeySecret
      ? twilio(apiKeySid, apiKeySecret, { accountSid })
      : twilio(accountSid, authToken);
  }
  return client;
}
