// Owner monetization: a 7-day free trial that starts when a user becomes an
// owner, followed by a one-time inscription fee. An owner who is past the trial
// and hasn't paid is "inactive" — their listings are hidden everywhere and they
// can't be contacted.

export const OWNER_TRIAL_DAYS = 7;
export const OWNER_INSCRIPTION_FEE_FCFA = 5000;

const DAY_MS = 24 * 60 * 60 * 1000;

type OwnerFields = {
  isOwner: boolean;
  ownerPaid: boolean;
  ownerTrialStartedAt: Date | null;
};

/** End of the free trial, or null when there is no trial in progress. */
export function ownerTrialEndsAt(startedAt: Date | null): Date | null {
  return startedAt ? new Date(startedAt.getTime() + OWNER_TRIAL_DAYS * DAY_MS) : null;
}

/**
 * Whether an owner account is active (dashboard usable, listings visible,
 * contactable). Non-owners are always "active" (the flag doesn't apply). A
 * paid owner is active forever. A legacy owner with no recorded trial start is
 * grandfathered in as active.
 */
export function ownerActive(u: OwnerFields): boolean {
  if (!u.isOwner) return true;
  if (u.ownerPaid) return true;
  if (!u.ownerTrialStartedAt) return true;
  return ownerTrialEndsAt(u.ownerTrialStartedAt)!.getTime() > Date.now();
}

/** Whole days left in the trial, or null when not in a running trial. */
export function ownerTrialDaysLeft(u: OwnerFields): number | null {
  if (!u.isOwner || u.ownerPaid || !u.ownerTrialStartedAt) return null;
  const ms = ownerTrialEndsAt(u.ownerTrialStartedAt)!.getTime() - Date.now();
  return ms <= 0 ? 0 : Math.ceil(ms / DAY_MS);
}

/**
 * Prisma filter fragment, applied to a listing's `owner` relation, that keeps
 * only listings whose owner is active: not an owner, paid, legacy (no trial
 * start) or still inside the trial.
 *
 * Written as an explicit OR on purpose. The previous form,
 * `NOT { isOwner, !ownerPaid, ownerTrialStartedAt < cutoff }`, compiles to SQL
 * where `NULL < cutoff` is NULL and `NOT (… AND NULL)` is also NULL — so every
 * legacy owner (null trial start) was filtered out and the public feed went
 * empty in production.
 */
export function activeOwnerRelationWhere() {
  const cutoff = new Date(Date.now() - OWNER_TRIAL_DAYS * DAY_MS);
  return {
    OR: [
      { isOwner: false },
      { ownerPaid: true },
      { ownerTrialStartedAt: null },
      { ownerTrialStartedAt: { gte: cutoff } },
    ],
  };
}
