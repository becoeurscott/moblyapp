import { notifyUser } from './push';

/**
 * First item in a new account's notification list. Called once, right after
 * the account row is created (form signup, OAuth signup, OAuth + phone) — never
 * on sign-in, so it can't repeat.
 *
 * Fire-and-forget: a notification failure must never fail the signup that
 * triggered it.
 */
export function sendWelcomeNotification(userId: string, fullName?: string | null): void {
  const first = (fullName ?? '').trim().split(/\s+/)[0];
  const name = first && first !== 'Utilisateur' ? ` ${first}` : '';
  notifyUser({
    userId,
    type: 'WELCOME',
    title: `Bienvenue sur Mobly${name} 👋`,
    body:
      'Trouvez une chambre, un studio, un bureau ou une boutique partout au Cameroun. ' +
      'Enregistrez vos coups de cœur, échangez directement avec les propriétaires ' +
      'et publiez votre propre espace quand vous voulez.',
  }).catch((err) => console.error('[welcome] notification failed', { userId, err: String(err) }));
}
