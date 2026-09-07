import type { AdminRole } from '@prisma/client';

/**
 * What each admin tier may do.
 *
 * Ranked, not orthogonal: every role can do everything the roles below it can.
 * That keeps the check to a single comparison and makes "who can undo this?"
 * answerable at a glance — important when the actions on the other side are
 * things like banning an account or turning chat off for the whole country.
 *
 * The same table is mirrored in `admin/lib/permissions.ts` so the dashboard can
 * hide buttons. The dashboard copy is cosmetic only: this file is the one that
 * decides, and every endpoint is checked server-side regardless of what the UI
 * chose to render.
 */
export const ROLE_RANK: Record<AdminRole, number> = {
  READ_ONLY: 0,
  SUPPORT: 1,
  MODERATOR: 2,
  ADMIN: 3,
  SUPER_ADMIN: 4,
};

export const ROLE_LABEL: Record<AdminRole, string> = {
  READ_ONLY: 'Lecture seule',
  SUPPORT: 'Support',
  MODERATOR: 'Modérateur',
  ADMIN: 'Admin',
  SUPER_ADMIN: 'Super admin',
};

/**
 * Minimum role per capability. Grouped by the blast radius of the action:
 * reading is harmless, support touches one user's session, moderation changes
 * what other users see, admin changes how the product behaves, and super admin
 * changes who is allowed to do any of it.
 */
export const PERMISSIONS = {
  // READ_ONLY — every GET on the admin surface.
  'admin.read': 'READ_ONLY',

  // SUPPORT — acts on a single user, reversibly.
  'user.notify': 'SUPPORT',
  'user.passwordReset': 'SUPPORT',
  'user.forceLogout': 'SUPPORT',
  'user.session.revoke': 'SUPPORT',
  'user.device.remove': 'SUPPORT',
  'user.unlock': 'SUPPORT',
  'visit.update': 'SUPPORT',
  'report.triage': 'SUPPORT',

  // MODERATOR — changes what other users see.
  'user.restrict': 'MODERATOR',
  'user.suspend': 'MODERATOR',
  'listing.moderate': 'MODERATOR',
  'listing.photo.remove': 'MODERATOR',
  'message.delete': 'MODERATOR',
  'thread.moderate': 'MODERATOR',
  'review.moderate': 'MODERATOR',
  'report.action': 'MODERATOR',
  'moderation.blocklist': 'MODERATOR',

  // ADMIN — changes the product itself.
  'user.edit': 'ADMIN',
  'user.identity': 'ADMIN',
  'user.export': 'ADMIN',
  'user.delete': 'ADMIN',
  'listing.edit': 'ADMIN',
  'listing.delete': 'ADMIN',
  'listing.transfer': 'ADMIN',
  'listing.boost': 'ADMIN',
  'listing.pin': 'ADMIN',
  'config.write': 'ADMIN',
  'notification.broadcast': 'ADMIN',
  'maintenance.write': 'ADMIN',
  'system.write': 'ADMIN',
  'export.download': 'ADMIN',

  // SUPER_ADMIN — changes who may do the above.
  'admin.role.assign': 'SUPER_ADMIN',
  'security.write': 'SUPER_ADMIN',
  'security.forceLogoutAll': 'SUPER_ADMIN',
  'admin.session.revoke': 'SUPER_ADMIN',
} as const satisfies Record<string, AdminRole>;

export type Permission = keyof typeof PERMISSIONS;

export const ALL_PERMISSIONS = Object.keys(PERMISSIONS) as Permission[];

export function can(role: AdminRole | null | undefined, permission: Permission): boolean {
  if (!role) return false;
  return ROLE_RANK[role] >= ROLE_RANK[PERMISSIONS[permission]];
}

/** Everything a role is allowed to do — sent to the dashboard on login. */
export function permissionsFor(role: AdminRole | null | undefined): Permission[] {
  if (!role) return [];
  return ALL_PERMISSIONS.filter((p) => can(role, p));
}

/**
 * May `actor` act on `target`?
 *
 * An admin can never act on a peer or a superior — otherwise two ADMINs could
 * demote each other, and a MODERATOR could ban the SUPER_ADMIN who supervises
 * them. Only a SUPER_ADMIN may act on another SUPER_ADMIN.
 */
export function canActOn(
  actorRole: AdminRole | null | undefined,
  targetRole: AdminRole | null | undefined
): boolean {
  if (!actorRole) return false;
  if (!targetRole) return true; // target is a normal user
  if (actorRole === 'SUPER_ADMIN') return true;
  return ROLE_RANK[actorRole] > ROLE_RANK[targetRole];
}
