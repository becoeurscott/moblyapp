/**
 * Password policy.
 *
 * Enforced server-side because client validation is a UX affordance, not a
 * control — anything calling the API directly bypasses it entirely. The client
 * runs the same rules for live feedback; this is the one that counts.
 *
 * Every failed rule is returned at once (rather than stopping at the first) so
 * the UI can tick off a checklist instead of making the user resubmit to
 * discover the next problem.
 */

export const PASSWORD_MIN = 8;
export const PASSWORD_MAX = 128; // bcrypt silently truncates past 72 bytes; cap well before surprises

export type PasswordRule =
  | 'TOO_SHORT'
  | 'TOO_LONG'
  | 'NEEDS_LOWERCASE'
  | 'NEEDS_UPPERCASE'
  | 'NEEDS_DIGIT'
  | 'TOO_COMMON'
  | 'CONTAINS_PERSONAL';

/** French copy per rule, shown inline next to the field. */
export const PASSWORD_RULE_MESSAGES: Record<PasswordRule, string> = {
  TOO_SHORT: `Au moins ${PASSWORD_MIN} caractères`,
  TOO_LONG: `Maximum ${PASSWORD_MAX} caractères`,
  NEEDS_LOWERCASE: 'Au moins une minuscule',
  NEEDS_UPPERCASE: 'Au moins une majuscule',
  NEEDS_DIGIT: 'Au moins un chiffre',
  TOO_COMMON: 'Ce mot de passe est trop courant',
  CONTAINS_PERSONAL: 'Évitez votre nom, e-mail ou numéro',
};

/**
 * Passwords that survive the character rules but fall instantly to a
 * dictionary attack. Deliberately small and local — the point is to block the
 * handful people actually reach for, not to ship a breach corpus.
 */
const COMMON = new Set([
  'password', 'password1', 'password123', 'passw0rd', 'motdepasse',
  'motdepasse1', 'motdepasse123', 'azerty123', 'qwerty123', 'azertyuiop',
  '12345678', '123456789', '1234567890', 'abcd1234', 'abc12345',
  'iloveyou1', 'welcome1', 'admin123', 'cameroun1', 'cameroun123',
  'douala123', 'yaounde123', 'mobly123', 'mobly1234',
]);

export interface PasswordCheck {
  ok: boolean;
  failed: PasswordRule[];
  /** 0–4, for a strength meter. Only meaningful once `ok` is true. */
  score: number;
}

/**
 * @param personal name / email / phone, so a password can't just restate them.
 */
export function checkPassword(password: string, personal: string[] = []): PasswordCheck {
  const failed: PasswordRule[] = [];

  if (password.length < PASSWORD_MIN) failed.push('TOO_SHORT');
  if (password.length > PASSWORD_MAX) failed.push('TOO_LONG');
  if (!/[a-z]/.test(password)) failed.push('NEEDS_LOWERCASE');
  if (!/[A-Z]/.test(password)) failed.push('NEEDS_UPPERCASE');
  if (!/[0-9]/.test(password)) failed.push('NEEDS_DIGIT');

  const lower = password.toLowerCase();
  if (COMMON.has(lower)) failed.push('TOO_COMMON');

  // "Jeanne2024" for Jeanne Ndongo, or a password carrying the phone number, is
  // guessable by anyone who knows the person. Each value is broken into its
  // parts first — a full name never appears verbatim in a password, but a first
  // name very often does.
  if (personal.some((raw) => containsPersonal(lower, raw))) {
    failed.push('CONTAINS_PERSONAL');
  }

  return { ok: failed.length === 0, failed, score: strength(password) };
}

/**
 * Does `lower` embed a recognisable piece of `raw`?
 *
 * Names are split on whitespace, emails reduced to their local part (itself
 * split on dots), and phone numbers matched on their last 6 digits — the part
 * a person would actually reuse, since the +237 prefix is shared by everyone.
 */
function containsPersonal(lower: string, raw: string): boolean {
  const value = (raw ?? '').toLowerCase().trim();
  if (!value) return false;

  const digits = value.replace(/\D/g, '');
  if (digits.length >= 6 && lower.includes(digits.slice(-6))) return true;

  const local = value.includes('@') ? value.split('@')[0] : value;
  return local
    .split(/[\s._-]+/)
    .filter((part) => part.length >= 4 && /[a-z]/.test(part))
    .some((part) => lower.includes(part));
}

/** Rough 0–4 strength, for the meter only — never a substitute for the rules. */
function strength(password: string): number {
  let score = 0;
  if (password.length >= PASSWORD_MIN) score++;
  if (password.length >= 12) score++;
  if (/[a-z]/.test(password) && /[A-Z]/.test(password)) score++;
  if (/[0-9]/.test(password)) score++;
  if (/[^A-Za-z0-9]/.test(password)) score++;
  return Math.min(4, score);
}
