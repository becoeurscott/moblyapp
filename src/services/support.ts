import { prisma } from '../lib/prisma';
import { ApiError } from '../lib/http';

/**
 * The in-app support channel.
 *
 * Support is a normal conversation, not a separate system: the user writes to
 * a "Support Mobly" account in the Messages tab, and an admin answers from the
 * dashboard as that same account. Reusing the chat stack means support
 * inherits real-time delivery, push, offline history, read receipts and the
 * moderation tools for free — and the user never has to leave the app or
 * remember an e-mail address.
 *
 * The identity is shared deliberately. Whoever is on duty replies, and the
 * user always sees one consistent contact instead of a rotating cast of staff
 * names; the audit log still records which admin actually sent each message.
 */

/** The support account's phone. Never receives SMS — it cannot sign in. */
const SUPPORT_PHONE = '+237000000001';
const SUPPORT_NAME = 'Support Mobly';

/**
 * Cached because it is resolved on every support request and never changes.
 * Only the id is held, so a rename or avatar change is picked up on the next
 * read of the row itself.
 */
let cachedId: string | null = null;

export function bustSupportCache() {
  cachedId = null;
}

/**
 * The support account, created on first use.
 *
 * Self-provisioning rather than seed-dependent: a fresh database (or the
 * Supabase project coming back empty, which has happened here before) would
 * otherwise leave the support button throwing 500s until someone remembered to
 * run a script.
 */
export async function getSupportUser(): Promise<{ id: string; fullName: string }> {
  if (cachedId) {
    const hit = await prisma.user.findUnique({
      where: { id: cachedId },
      select: { id: true, fullName: true },
    });
    if (hit) return hit;
    cachedId = null; // row disappeared — fall through and re-resolve
  }

  const existing = await prisma.user.findFirst({
    where: { isSupport: true },
    select: { id: true, fullName: true },
  });
  if (existing) {
    cachedId = existing.id;
    return existing;
  }

  const created = await prisma.user.create({
    data: {
      phone: SUPPORT_PHONE,
      fullName: SUPPORT_NAME,
      isSupport: true,
      // Verified so the app renders the trust badge on the conversation, and
      // active so nothing in `requireAuth` trips over it. It holds no password
      // and no OAuth identity, so there is no way to sign in as it.
      verified: true,
      isActive: true,
      avatarColor: '#3A4FF0',
      city: 'Douala',
    },
    select: { id: true, fullName: true },
  });
  cachedId = created.id;
  return created;
}

/** True when this thread is a support conversation. */
export async function isSupportThread(threadId: string): Promise<boolean> {
  const support = await getSupportUser();
  const row = await prisma.threadParticipant.findUnique({
    where: { threadId_userId: { threadId, userId: support.id } },
    select: { id: true },
  });
  return row !== null;
}

/**
 * The caller's support conversation, created on first contact.
 *
 * One thread per user, forever: reopening "Contacter le support" returns the
 * same conversation so the history an agent needs is all in one place, rather
 * than fragmenting into a new thread per question.
 */
export async function getOrCreateSupportThread(userId: string) {
  const support = await getSupportUser();
  if (support.id === userId) {
    throw new ApiError(422, 'Compte support', 'VALIDATION_FAILED');
  }

  const existing = await prisma.thread.findFirst({
    where: {
      listingId: null,
      AND: [
        { participants: { some: { userId } } },
        { participants: { some: { userId: support.id } } },
      ],
    },
    select: { id: true },
  });
  if (existing) return { threadId: existing.id, created: false, supportId: support.id };

  const thread = await prisma.thread.create({
    data: {
      participants: { create: [{ userId }, { userId: support.id }] },
    },
    select: { id: true },
  });
  return { threadId: thread.id, created: true, supportId: support.id };
}
