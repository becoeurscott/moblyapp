import { notifyUser, pushToUser } from './push';
import { prisma } from '../lib/prisma';
import { OWNER_TRIAL_DAYS } from '../lib/ownerTrial';
import { greetingFirstName } from '../lib/displayName';

/**
 * A new account's first notifications, created right after the account row
 * (form signup, OAuth signup, OAuth + phone) — never on sign-in, so they can't
 * repeat:
 *   1. "Confirmez votre e-mail"  → opens the e-mail confirmation screen
 *   2. "Devenez propriétaire"    → starts the become-owner flow
 *   3. "Bienvenue sur Mobly"     → created last, so it sits on top
 * The app routes 1 and 2 on `payload.action`. Each is skipped when it no longer
 * applies (already an owner, address already confirmed).
 *
 * Fire-and-forget: a notification failure must never fail the signup that
 * triggered it.
 */
export function sendWelcomeNotifications(user: {
  id: string;
  fullName?: string | null;
  isOwner?: boolean | null;
  email?: string | null;
  emailVerifiedAt?: Date | null;
}): void {
  const first = greetingFirstName(user.fullName, user.email);
  const name = first ? ` ${first}` : '';

  (async () => {
    // Sequential, oldest first: the list is newest-first, and the welcome
    // must read first.
    if (!user.emailVerifiedAt) {
      await notifyUser({
        userId: user.id,
        type: 'VERIFY_EMAIL',
        title: user.email ? 'Confirmez votre adresse e-mail' : 'Ajoutez votre adresse e-mail',
        body: user.email
          ? `Confirmez ${user.email} avec un code : vous pourrez récupérer votre compte par e-mail si vous perdez votre numéro.`
          : 'Ajoutez et confirmez une adresse e-mail pour pouvoir récupérer votre compte si vous perdez votre numéro.',
        payload: { action: 'verify_email' },
      });
    }
    if (!user.isOwner) {
      await notifyUser({
        userId: user.id,
        type: 'OWNER_INVITE',
        title: 'Vous avez un espace à louer ?',
        body:
          `Devenez propriétaire sur Mobly : publiez vos annonces gratuitement pendant ${OWNER_TRIAL_DAYS} jours ` +
          'et faites connaître vos espaces partout au Cameroun.',
        payload: { action: 'become_owner' },
      });
    }
    await notifyUser({
      userId: user.id,
      type: 'WELCOME',
      title: `Bienvenue sur Mobly${name} 👋`,
      body:
        'Trouvez une chambre, un studio, un bureau ou une boutique partout au Cameroun. ' +
        'Enregistrez vos coups de cœur, échangez directement avec les propriétaires ' +
        'et publiez votre propre espace quand vous voulez.',
    });
  })().catch((err) => console.error('[welcome] notifications failed', { userId: user.id, err: String(err) }));
}

const LATE_WELCOME_WINDOW_MS = 10 * 60 * 1000;

/**
 * Pushes the WELCOME notification once a device token exists, for accounts
 * created in the last 10 minutes. Idempotent: the notification's payload is
 * stamped `latePushed` with a compare-and-set update, so concurrent or
 * repeated registrations (the app re-registers on every launch) push it at
 * most once.
 */
export async function resendWelcomePushOnFirstDevice(userId: string): Promise<void> {
  const since = new Date(Date.now() - LATE_WELCOME_WINDOW_MS);
  const n = await prisma.notification.findFirst({
    where: { userId, type: 'WELCOME', read: false, createdAt: { gte: since } },
    orderBy: { createdAt: 'desc' },
  });
  if (!n) return;
  const payload = (n.payload && typeof n.payload === 'object' && !Array.isArray(n.payload)
    ? (n.payload as Record<string, string>)
    : {}) as Record<string, string>;
  if (payload.latePushed) return;
  // A device registered before the notification already got the original push.
  const earlier = await prisma.device.count({
    where: { userId, pushToken: { not: null }, createdAt: { lt: n.createdAt } },
  });
  if (earlier > 0) return;

  const claimed = await prisma.notification.updateMany({
    where: { id: n.id, payload: { equals: n.payload ?? {} } },
    data: { payload: { ...payload, latePushed: '1' } },
  });
  if (claimed.count !== 1) return; // another registration got there first

  await pushToUser(userId, { type: n.type, title: n.title, body: n.body ?? '', data: payload });
}
