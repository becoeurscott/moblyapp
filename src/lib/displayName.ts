/**
 * First name to greet a user with, or '' when we have no real name.
 * Never derives a name from the e-mail: an address, an e-mail local part or
 * the "Utilisateur Mobly" placeholder all yield '' so the copy falls back to
 * a plain "Bienvenue" / "Bonjour".
 */
export function greetingFirstName(fullName?: string | null, email?: string | null): string {
  const full = (fullName ?? '').trim();
  if (!full || full.includes('@') || full === 'Utilisateur Mobly') return '';
  const local = (email ?? '').split('@')[0]?.trim().toLowerCase();
  if (local && full.toLowerCase() === local) return '';
  return full.split(/\s+/)[0] ?? '';
}
