import crypto from 'node:crypto';
import { env } from '../config/env';
import { ApiError } from '../lib/http';

/**
 * Didit identity verification (https://docs.didit.me).
 *
 * Mobly uses the *hosted* flow: we create a session server-side, hand the app a
 * one-shot URL, and Didit tells us the outcome over a signed webhook. The
 * document photos and the selfie never touch this backend, which is the whole
 * point — no ID scans in our database, no liveness pipeline to maintain.
 */

/** Didit's own session statuses, verbatim from the webhook `status` field. */
export type DiditStatus =
  | 'Not Started'
  | 'In Progress'
  | 'In Review'
  | 'Approved'
  | 'Declined'
  | 'Abandoned'
  | 'Resubmission Requested'
  | string;

export type IdentityStatus = 'PENDING' | 'IN_REVIEW' | 'APPROVED' | 'DECLINED' | 'ABANDONED';

/**
 * Collapse Didit's status vocabulary onto ours.
 *
 * Anything unrecognised stays PENDING on purpose: a status we have not seen
 * before must never be read as "approved", and leaving it pending keeps the
 * user in the flow instead of falsely telling them they were rejected.
 */
export function mapStatus(status: DiditStatus): IdentityStatus {
  switch (status) {
    case 'Approved':
      return 'APPROVED';
    case 'Declined':
      return 'DECLINED';
    case 'Abandoned':
      return 'ABANDONED';
    case 'In Review':
    case 'Resubmission Requested':
      return 'IN_REVIEW';
    default:
      return 'PENDING';
  }
}

export interface DiditSession {
  sessionId: string;
  url: string;
}

async function diditFetch<T>(path: string, init: RequestInit = {}): Promise<T> {
  if (!env.didit.configured) {
    throw new ApiError(503, "La vérification d'identité est indisponible", 'INTERNAL');
  }

  // Didit is a third party on the critical path of a user-facing tap. Without a
  // deadline a hung connection would hold the request open until the platform
  // kills it, and the user would just watch a spinner.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 15_000);

  let res: Response;
  try {
    res = await fetch(`${env.didit.baseUrl}${path}`, {
      ...init,
      signal: controller.signal,
      headers: {
        'x-api-key': env.didit.apiKey,
        'Content-Type': 'application/json',
        ...(init.headers ?? {}),
      },
    });
  } catch (err) {
    if (err instanceof ApiError) throw err;
    console.error('[didit] request failed', path, err);
    throw new ApiError(502, 'Service de vérification injoignable', 'INTERNAL');
  } finally {
    clearTimeout(timeout);
  }

  const text = await res.text();
  if (!res.ok) {
    // The provider's error prose is English and aimed at us, not the user, so it
    // goes to the log and the client gets a French message it can display.
    console.error(`[didit] ${init.method ?? 'GET'} ${path} → ${res.status}: ${text.slice(0, 500)}`);
    throw new ApiError(502, 'Service de vérification indisponible', 'INTERNAL');
  }

  try {
    return JSON.parse(text) as T;
  } catch {
    throw new ApiError(502, 'Réponse invalide du service de vérification', 'INTERNAL');
  }
}

/**
 * Create a hosted verification session.
 *
 * `vendorData` is our own user id; Didit echoes it back on the webhook, which
 * is what lets a decision be attributed without trusting anything the client says.
 */
export async function createSession(vendorData: string): Promise<DiditSession> {
  const body = await diditFetch<{ session_id: string; url: string }>('/v3/session/', {
    method: 'POST',
    body: JSON.stringify({
      workflow_id: env.didit.workflowId,
      vendor_data: vendorData,
      callback: env.didit.callbackUrl,
    }),
  });

  if (!body.session_id || !body.url) {
    throw new ApiError(502, 'Réponse invalide du service de vérification', 'INTERNAL');
  }
  return { sessionId: body.session_id, url: body.url };
}

/** Poll a session's decision — the fallback when a webhook was missed. */
export async function retrieveDecision(
  sessionId: string
): Promise<{ status: DiditStatus; raw: unknown }> {
  const body = await diditFetch<{ status?: DiditStatus }>(
    `/v3/session/${encodeURIComponent(sessionId)}/decision/`
  );
  return { status: body.status ?? 'Not Started', raw: body };
}

// ─────────────────────────────────────────────────────────────
// Webhook signature
// ─────────────────────────────────────────────────────────────

/**
 * Canonical JSON for `X-Signature-V2`: recursively sorted keys, compact
 * separators, unescaped Unicode, whole-valued floats written as integers.
 *
 * We verify V2 rather than the raw-body `X-Signature` because Express has
 * already parsed and re-encoded the body by the time this runs — V2 exists
 * precisely so a re-serialised payload still validates.
 */
export function canonicalJSON(value: unknown): string {
  if (value === null || typeof value === 'boolean' || typeof value === 'string') {
    return JSON.stringify(value);
  }
  if (typeof value === 'number') {
    // 12.0 must serialise as "12": Python's json emits the integer form, so a
    // JS "12" vs "12.0" mismatch would break every signature carrying a float.
    return Number.isFinite(value) && Number.isInteger(value)
      ? String(Math.trunc(value))
      : JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(canonicalJSON).join(',')}]`;
  }
  if (typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>)
      .filter(([, v]) => v !== undefined)
      // Code-point order, which is what String#localeCompare would get wrong.
      .sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
    return `{${entries.map(([k, v]) => `${JSON.stringify(k)}:${canonicalJSON(v)}`).join(',')}}`;
  }
  return 'null';
}

function timingSafeEqualHex(a: string, b: string): boolean {
  const bufA = Buffer.from(a, 'utf8');
  const bufB = Buffer.from(b, 'utf8');
  // timingSafeEqual throws on a length mismatch, which would itself leak the
  // length — compare fixed-size digests of the two strings instead.
  const hashA = crypto.createHash('sha256').update(bufA).digest();
  const hashB = crypto.createHash('sha256').update(bufB).digest();
  return crypto.timingSafeEqual(hashA, hashB);
}

export interface WebhookHeaders {
  signatureV2?: string;
  signatureSimple?: string;
  timestamp?: string;
}

/**
 * Verify an incoming webhook. Returns true only for a fresh, correctly signed
 * payload — an unsigned or stale request is a forged verified badge, so this is
 * fail-closed in every branch, including a missing secret.
 */
export function verifyWebhook(body: Record<string, unknown>, headers: WebhookHeaders): boolean {
  const secret = env.didit.webhookSecret;
  if (!secret) {
    console.error('[didit] DIDIT_WEBHOOK_SECRET is not set — rejecting webhook');
    return false;
  }

  // Replay window. A captured "Approved" body is otherwise valid forever.
  const ts = Number(headers.timestamp);
  if (!Number.isFinite(ts) || Math.abs(Date.now() / 1000 - ts) > 300) return false;

  if (headers.signatureV2) {
    const expected = crypto
      .createHmac('sha256', secret)
      .update(canonicalJSON(body), 'utf8')
      .digest('hex');
    if (timingSafeEqualHex(expected, headers.signatureV2)) return true;
  }

  // Envelope-only fallback. It does not cover `decision`, so we still re-read
  // the status from the provider before trusting it (see the route).
  if (headers.signatureSimple) {
    const payload = `${headers.timestamp}:${body.session_id}:${body.status}:${body.webhook_type}`;
    const expected = crypto.createHmac('sha256', secret).update(payload, 'utf8').digest('hex');
    if (timingSafeEqualHex(expected, headers.signatureSimple)) return true;
  }

  return false;
}
