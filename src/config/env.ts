import dotenv from 'dotenv';

dotenv.config();

function required(name: string, fallback?: string): string {
  const v = process.env[name] ?? fallback;
  if (v === undefined) throw new Error(`Missing required env var: ${name}`);
  return v;
}

const nodeEnv = process.env.NODE_ENV ?? 'development';
const isProd = nodeEnv === 'production';

/** `TRUST_PROXY` accepts a hop count ("1"), a boolean, or an empty value (off). */
function trustProxy(): boolean | number {
  const raw = (process.env.TRUST_PROXY ?? '').trim();
  if (!raw) return false;
  if (raw === 'true') return true;
  if (raw === 'false') return false;
  const n = parseInt(raw, 10);
  return Number.isNaN(n) ? false : n;
}

export const env = {
  // Runtime
  port: parseInt(process.env.PORT ?? '4000', 10),
  nodeEnv,
  isProd,
  /** Where the API is mounted, e.g. "/api/v1". Always starts with "/". */
  apiPrefix: (process.env.API_PREFIX ?? '/api').replace(/\/+$/, '') || '/api',
  trustProxy: trustProxy(),
  corsOrigins: (process.env.CORS_ORIGINS ?? '*')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean),

  // Database — DIRECT_URL is read by Prisma (schema.prisma) for migrations only.
  databaseUrl: required('DATABASE_URL'),

  // Auth. JWT_SECRET / JWT_EXPIRES_IN are the legacy single-token names and are
  // still honoured so older .env files keep working.
  jwtSecret: required(
    'JWT_ACCESS_SECRET',
    process.env.JWT_SECRET ?? (isProd ? undefined : 'dev-insecure-secret-change-me')
  ),
  // Short-lived by design: revocation happens at the refresh step, so a long
  // access token would stay usable well after a session is killed.
  jwtExpiresIn: process.env.JWT_ACCESS_TTL ?? process.env.JWT_EXPIRES_IN ?? '15m',
  jwtRefreshSecret: process.env.JWT_REFRESH_SECRET ?? '',
  jwtRefreshExpiresIn: process.env.JWT_REFRESH_TTL ?? '30d',
  otpDevMode: (process.env.OTP_DEV_MODE ?? String(!isProd)) === 'true',

  /**
   * Accepted audiences for provider ID tokens. Pinning these is what prevents
   * a token minted for someone else's app being replayed against Mobly, so an
   * empty list disables that provider rather than accepting anything.
   * Comma-separated; Google web + iOS client ids can both be listed.
   */
  oauth: {
    googleClientIds: (process.env.GOOGLE_CLIENT_IDS ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
    appleBundleIds: (process.env.APPLE_BUNDLE_IDS ?? 'cm.mobly.app')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  },

  /**
   * Twilio (SMS delivery for OTP).
   *
   * `SMS_ALLOWED_COUNTRIES` is a comma-separated list of E.164 dial prefixes
   * (no `+`) the app is willing to text. It defaults to Cameroon plus the main
   * diaspora markets — leaving it wide open is how SMS pumping bills add up,
   * since the app now lets a user pick any country.
   */
  twilio: {
    accountSid: process.env.TWILIO_ACCOUNT_SID ?? '',
    authToken: process.env.TWILIO_AUTH_TOKEN ?? '',
    /**
     * API Key credentials — the preferred alternative to the account Auth
     * Token. An API Key can be revoked on its own without invalidating every
     * other integration, so a leak is recoverable; the Auth Token is
     * account-wide. If both are set, the API Key wins.
     */
    apiKeySid: process.env.TWILIO_API_KEY_SID ?? '',
    apiKeySecret: process.env.TWILIO_API_KEY_SECRET ?? '',
    fromNumber: process.env.TWILIO_FROM_NUMBER ?? '',
    messagingServiceSid: process.env.TWILIO_MESSAGING_SERVICE_SID ?? '',
    verifyServiceSid: process.env.TWILIO_VERIFY_SERVICE_SID ?? '',
    allowedPrefixes: (process.env.SMS_ALLOWED_COUNTRIES ?? '237,33,32,1,44,49,41,39,34')
      .split(',')
      .map((s) => s.trim().replace(/^\+/, ''))
      .filter(Boolean),
    /** True when we have an account, some credential, and a way to send. */
    get configured(): boolean {
      const hasCredential =
        Boolean(this.authToken) || Boolean(this.apiKeySid && this.apiKeySecret);
      return Boolean(
        this.accountSid
          && hasCredential
          && (this.fromNumber || this.messagingServiceSid || this.verifyServiceSid)
      );
    },
  },

  /**
   * Apple Push Notifications (token-based auth).
   *
   * `APNS_KEY` is the contents of the .p8 file — newlines may be written as
   * literal \n so it fits on one .env line. `APNS_PRODUCTION` picks the live
   * gateway; a TestFlight/App Store build needs it true, a development build
   * needs it false, and getting it wrong yields silent `BadDeviceToken`.
   */
  apns: {
    keyId: process.env.APNS_KEY_ID ?? '',
    teamId: process.env.APNS_TEAM_ID ?? '',
    /**
     * The .p8 contents. Prefer `APNS_KEY_PATH` — a multi-line PEM squeezed onto
     * one .env line is a reliable source of "invalid key" errors, and keeping
     * the file on disk (chmod 600, gitignored) is easier to rotate.
     */
    get key(): string {
      const path = process.env.APNS_KEY_PATH;
      if (path) {
        try {
          // eslint-disable-next-line @typescript-eslint/no-var-requires
          return require('node:fs').readFileSync(path, 'utf8');
        } catch {
          console.error(`[apns] cannot read key at ${path}`);
          return '';
        }
      }
      return process.env.APNS_KEY ?? '';
    },
    bundleId: process.env.APNS_BUNDLE_ID ?? 'cm.mobly.app',
    production: process.env.APNS_PRODUCTION === 'true',
    get configured(): boolean {
      return Boolean(this.keyId && this.teamId && this.key && this.bundleId);
    },
  },

  // Cloudinary (image storage + CDN)
  cloudinary: {
    cloudName: process.env.CLOUDINARY_CLOUD_NAME ?? '',
    apiKey: process.env.CLOUDINARY_API_KEY ?? '',
    apiSecret: process.env.CLOUDINARY_API_SECRET ?? '',
    folder: process.env.CLOUDINARY_UPLOAD_FOLDER ?? 'mobly/listings',
    get configured(): boolean {
      return Boolean(this.cloudName && this.apiKey && this.apiSecret);
    },
  },

  /** Share-a-listing template only. Contact stays in-app (2026 pivot). */
  whatsappShareTemplate:
    process.env.WHATSAPP_MESSAGE_TEMPLATE ??
    'Bonjour, j\'ai vu votre annonce "{title}" sur Mobly et je suis intéressé.',

  // Cron — shared secret that protects scheduled endpoints from public access.
  cronSecret: process.env.CRON_SECRET ?? (isProd ? '' : 'dev-cron-secret'),

  /**
   * Didit (https://didit.me) — hosted identity verification (pièce d'identité
   * + selfie), the engine behind `User.identityVerified`.
   *
   * `DIDIT_API_KEY` is server-only and must never reach the app: the phone
   * receives a one-shot hosted URL, nothing else. `DIDIT_WEBHOOK_SECRET` is the
   * `secret_shared_key` handed back once when the webhook destination is
   * created — without it every incoming webhook is rejected, since an unsigned
   * "Approved" would be a free verified badge for anyone who finds the URL.
   */
  didit: {
    apiKey: process.env.DIDIT_API_KEY ?? '',
    workflowId: process.env.DIDIT_WORKFLOW_ID ?? '',
    webhookSecret: process.env.DIDIT_WEBHOOK_SECRET ?? '',
    baseUrl: (process.env.DIDIT_BASE_URL ?? 'https://verification.didit.me').replace(/\/+$/, ''),
    /** Where Didit sends the user when the hosted flow ends. */
    callbackUrl: process.env.DIDIT_CALLBACK_URL ?? 'moblyapp://kyc/return',
    get configured(): boolean {
      return Boolean(this.apiKey && this.workflowId);
    },
  },

  // Payments — "stub" auto-settles so the boost flow is buildable without a PSP.
  payments: {
    provider: process.env.PAYMENTS_PROVIDER ?? 'stub',
    webhookSecret: process.env.PAYMENTS_WEBHOOK_SECRET ?? '',
    get isStub(): boolean {
      return this.provider === 'stub';
    },
  },
};
