import http2 from 'node:http2';
import { SignJWT, importPKCS8 } from 'jose';
import { prisma } from '../lib/prisma';
import { env } from '../config/env';

/**
 * Apple Push Notification service, over HTTP/2 with token-based auth.
 *
 * Implemented directly rather than via a wrapper library: APNs is a single
 * HTTP/2 POST with a signed JWT, the popular Node packages are thinly
 * maintained, and this keeps the auth path something we can actually inspect.
 *
 * The provider token is an ES256 JWT signed with the .p8 key. Apple caches it
 * for up to an hour and rejects tokens refreshed more than once every 20
 * minutes, so it's minted once and reused — regenerating per request gets the
 * whole app rate-limited with `TooManyProviderTokenUpdates`.
 */

const HOST_PROD = 'https://api.push.apple.com';
const HOST_SANDBOX = 'https://api.sandbox.push.apple.com';
/** Refresh comfortably inside Apple's 60-minute validity window. */
const TOKEN_TTL_MS = 45 * 60 * 1000;

let cachedToken: { value: string; mintedAt: number } | null = null;

export function pushConfigured(): boolean {
  return env.apns.configured;
}

async function providerToken(): Promise<string> {
  if (cachedToken && Date.now() - cachedToken.mintedAt < TOKEN_TTL_MS) {
    return cachedToken.value;
  }
  // The .p8 contents, with literal \n allowed so it can live in a .env line.
  const pem = env.apns.key.replace(/\\n/g, '\n');
  const key = await importPKCS8(pem, 'ES256');
  const value = await new SignJWT({})
    .setProtectedHeader({ alg: 'ES256', kid: env.apns.keyId })
    .setIssuer(env.apns.teamId)
    .setIssuedAt()
    .sign(key);
  cachedToken = { value, mintedAt: Date.now() };
  return value;
}

export interface PushPayload {
  title: string;
  body: string;
  /** Unread total, shown on the app icon. */
  badge?: number;
  /** Deep-link data — read by the app when the notification is tapped. */
  data?: Record<string, string>;
  threadId?: string;
}

interface SendResult {
  token: string;
  ok: boolean;
  status: number;
  reason?: string;
}

async function sendOne(deviceToken: string, payload: PushPayload): Promise<SendResult> {
  const jwt = await providerToken();
  const host = env.apns.production ? HOST_PROD : HOST_SANDBOX;

  const body = JSON.stringify({
    aps: {
      alert: { title: payload.title, body: payload.body },
      sound: 'default',
      ...(payload.badge !== undefined ? { badge: payload.badge } : {}),
      // Lets iOS coalesce updates for the same conversation instead of
      // stacking one banner per message.
      ...(payload.threadId ? { 'thread-id': payload.threadId } : {}),
    },
    ...payload.data,
  });

  return new Promise((resolve) => {
    const client = http2.connect(host);
    // Never let a stalled APNs connection hold a request open.
    const timer = setTimeout(() => {
      client.destroy();
      resolve({ token: deviceToken, ok: false, status: 0, reason: 'Timeout' });
    }, 10_000);

    client.on('error', () => {
      clearTimeout(timer);
      resolve({ token: deviceToken, ok: false, status: 0, reason: 'ConnectionError' });
    });

    const req = client.request({
      ':method': 'POST',
      ':path': `/3/device/${deviceToken}`,
      authorization: `bearer ${jwt}`,
      'apns-topic': env.apns.bundleId,
      'apns-push-type': 'alert',
      // 10 = deliver immediately. 5 would let iOS defer for power.
      'apns-priority': '10',
      'content-type': 'application/json',
      'content-length': Buffer.byteLength(body),
    });

    let status = 0;
    let raw = '';
    req.on('response', (headers) => {
      status = Number(headers[':status'] ?? 0);
    });
    req.on('data', (chunk) => (raw += chunk));
    req.on('end', () => {
      clearTimeout(timer);
      client.close();
      let reason: string | undefined;
      try {
        reason = raw ? JSON.parse(raw).reason : undefined;
      } catch {}
      resolve({ token: deviceToken, ok: status === 200, status, reason });
    });
    req.on('error', () => {
      clearTimeout(timer);
      client.destroy();
      resolve({ token: deviceToken, ok: false, status: 0, reason: 'StreamError' });
    });

    req.end(body);
  });
}

/**
 * Push to every device a user has registered.
 *
 * Best-effort by design: a failed push must never fail the request that
 * triggered it — the message is already saved, and the socket or a later
 * refresh will surface it regardless.
 */
export async function pushToUser(userId: string, payload: PushPayload): Promise<void> {
  if (!pushConfigured()) return;

  const devices = await prisma.device.findMany({
    where: { userId, pushToken: { not: null } },
    select: { id: true, pushToken: true },
  });
  if (devices.length === 0) return;

  const results = await Promise.all(
    devices.map((d) => sendOne(d.pushToken!, payload))
  );

  // Apple reports tokens that no longer belong to a live install. Leaving them
  // in the table means every future send wastes a request and slowly poisons
  // the account's reputation with APNs.
  const dead = results.filter(
    (r) => r.reason === 'BadDeviceToken' || r.reason === 'Unregistered'
  );
  if (dead.length) {
    await prisma.device.deleteMany({
      where: { pushToken: { in: dead.map((d) => d.token) } },
    });
    console.log(`[push] pruned ${dead.length} dead token(s)`);
  }

  const failed = results.filter((r) => !r.ok && !dead.includes(r));
  if (failed.length) {
    console.warn('[push] failures:', failed.map((f) => `${f.status} ${f.reason}`).join(', '));
  }
}

/**
 * Record the notification and push it — one call so the in-app list and the
 * banner can't drift apart.
 */
export async function notifyUser(opts: {
  userId: string;
  type: string;
  title: string;
  body: string;
  payload?: Record<string, string>;
  threadId?: string;
  badge?: number;
}): Promise<void> {
  await prisma.notification.create({
    data: {
      userId: opts.userId,
      type: opts.type,
      title: opts.title,
      body: opts.body,
      payload: opts.payload ?? {},
    },
  });
  await pushToUser(opts.userId, {
    title: opts.title,
    body: opts.body,
    badge: opts.badge,
    data: opts.payload,
    threadId: opts.threadId,
  });
}
