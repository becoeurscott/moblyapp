import { notifyUser } from './push';
import { OWNER_TRIAL_DAYS } from '../lib/ownerTrial';

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
  const first = (user.fullName ?? '').trim().split(/\s+/)[0];
  const name = first && first !== 'Utilisateur' ? ` ${first}` : '';

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
