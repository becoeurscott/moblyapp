import type { Request } from 'express';
import { prisma } from '../lib/prisma';

/**
 * Append-only record of every admin write.
 *
 * The remote-control surface can ban accounts, delete content and reconfigure
 * the product for every user at once. Without a trail there is no way to answer
 * "who turned chat off at 3am?" — so every mutating admin endpoint records what
 * changed, who changed it, and from where.
 *
 * Deliberately best-effort: a failure to write the log is reported to the
 * console but never propagated. An audit outage must not block moderation.
 */

export interface AuditInput {
  action: string;
  targetType?: string | null;
  targetId?: string | null;
  before?: unknown;
  after?: unknown;
}

/** Trim an object to the given keys — keeps the diff to what actually changed. */
export function pick<T extends object>(obj: T | null | undefined, keys: (keyof T)[]) {
  if (!obj) return null;
  const out: Record<string, unknown> = {};
  for (const k of keys) out[k as string] = obj[k];
  return out;
}

/**
 * Record only the fields a patch touched, on both sides. Passing whole rows
 * would bury the one changed field in forty unchanged ones.
 */
export function diff<T extends object>(before: T | null, after: T | null, patch: object) {
  const keys = Object.keys(patch) as (keyof T)[];
  return { before: pick(before, keys), after: pick(after, keys) };
}

export async function audit(req: Request, input: AuditInput): Promise<void> {
  const actorId = req.userId;
  if (!actorId) return;

  try {
    await prisma.adminAuditLog.create({
      data: {
        actorId,
        actorRole: req.user?.adminRole ?? null,
        action: input.action,
        targetType: input.targetType ?? null,
        targetId: input.targetId ?? null,
        before: (input.before ?? undefined) as never,
        after: (input.after ?? undefined) as never,
        ip: clientIp(req),
        userAgent: req.headers['user-agent']?.slice(0, 500) ?? null,
        requestId: req.id ?? null,
      },
    });
  } catch (err) {
    console.error(`[audit] failed to record "${input.action}":`, err);
  }
}

/**
 * Caller IP. Behind Render's proxy the socket address is the load balancer, so
 * the left-most `X-Forwarded-For` entry is the real client — that is the value
 * the admin IP allowlist compares against, so both must agree on it.
 */
export function clientIp(req: Request): string | null {
  const fwd = req.headers['x-forwarded-for'];
  if (typeof fwd === 'string' && fwd.length) return fwd.split(',')[0].trim();
  if (Array.isArray(fwd) && fwd.length) return fwd[0].split(',')[0].trim();
  return req.ip ?? req.socket.remoteAddress ?? null;
}
