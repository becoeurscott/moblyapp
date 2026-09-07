import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma';
import { asyncHandler, ApiError } from '../../lib/http';
import { requirePermission } from '../../middleware/auth';
import { audit, clientIp } from '../../lib/audit';
import { getConfig, setConfig, resetSection, configVersionSnapshot } from '../../services/config';
import { broadcastConfig } from '../../realtime/hub';
import {
  CONFIG_SECTIONS,
  RESTRICTED_SECTIONS,
  DEFAULT_CONFIG,
  FLAG_KEYS,
  type ConfigSection,
} from '../../config/appConfigSchema';
import { ROLE_LABEL } from '../../lib/permissions';

/** Feature flags, limits, copy, versions, geo, security policy. */
export const adminConfigRouter = Router();

/** GET /admin/config — the full document, including admin-only sections. */
adminConfigRouter.get(
  '/',
  asyncHandler(async (_req, res) => {
    const doc = await getConfig();
    res.json({
      config: doc,
      version: configVersionSnapshot(),
      // Shipped with the response so the dashboard can render a "reset to
      // default" affordance and show what each field started as.
      defaults: DEFAULT_CONFIG,
      sections: CONFIG_SECTIONS,
      restrictedSections: RESTRICTED_SECTIONS,
      flagKeys: FLAG_KEYS,
      roles: ROLE_LABEL,
    });
  })
);

/**
 * PUT /admin/config — apply a partial patch.
 *
 * Deep-merged, so the dashboard sends only what changed. The merged result is
 * re-validated before it is stored, which means a bad patch is rejected rather
 * than persisted into a document the app cannot parse.
 */
adminConfigRouter.put(
  '/',
  requirePermission('config.write'),
  asyncHandler(async (req, res) => {
    const patch = z.record(z.unknown()).parse(req.body);

    // The security section holds the admin IP allowlist and the OTP/password
    // policy — the controls that protect the admin surface itself. Only a
    // SUPER_ADMIN may touch them, whatever the caller's other privileges.
    const touchesRestricted = RESTRICTED_SECTIONS.some((s) => s in patch);
    if (touchesRestricted && req.user?.adminRole !== 'SUPER_ADMIN') {
      throw new ApiError(
        403,
        'Seul un super administrateur peut modifier les paramètres de sécurité.',
        'ROLE_REQUIRED'
      );
    }

    // Refuse an allowlist that would exclude the caller. Locking yourself out
    // of the only tool that can undo the lockout is a one-way door, and the
    // recovery is a manual database edit in production.
    const nextAllow = (patch as { security?: { adminIpAllowlist?: unknown } }).security
      ?.adminIpAllowlist;
    if (Array.isArray(nextAllow) && nextAllow.length) {
      const ip = clientIp(req);
      if (!ip || !nextAllow.includes(ip)) {
        throw new ApiError(
          400,
          `Cette liste exclut votre propre adresse (${ip ?? 'inconnue'}). ` +
            'Ajoutez-la avant d’enregistrer.',
          'VALIDATION_FAILED'
        );
      }
    }

    const { doc, version, before } = await setConfig(patch, req.userId!);

    // Tell every connected app to refetch. This is what makes a switch flipped
    // in the dashboard visible in the app within a second rather than at the
    // next poll.
    broadcastConfig(version);

    await audit(req, {
      action: 'config.update',
      targetType: 'config',
      targetId: 'singleton',
      // Only the touched sections are recorded, so the audit diff stays
      // readable instead of being the whole document twice.
      before: Object.fromEntries(
        Object.keys(patch).map((k) => [k, (before as Record<string, unknown>)[k]])
      ),
      after: Object.fromEntries(
        Object.keys(patch).map((k) => [k, (doc as Record<string, unknown>)[k]])
      ),
    });

    res.json({ config: doc, version });
  })
);

/** POST /admin/config/reset-section — restore one section to its defaults. */
adminConfigRouter.post(
  '/reset-section',
  requirePermission('config.write'),
  asyncHandler(async (req, res) => {
    const { section } = z
      .object({ section: z.enum(CONFIG_SECTIONS as unknown as [ConfigSection, ...ConfigSection[]]) })
      .parse(req.body);

    if (RESTRICTED_SECTIONS.includes(section) && req.user?.adminRole !== 'SUPER_ADMIN') {
      throw new ApiError(403, 'Réservé au super administrateur.', 'ROLE_REQUIRED');
    }

    const before = await getConfig();
    const { doc, version } = await resetSection(section, req.userId!);
    broadcastConfig(version);

    await audit(req, {
      action: 'config.resetSection',
      targetType: 'config',
      targetId: section,
      before: { [section]: before[section] },
      after: { [section]: doc[section] },
    });
    res.json({ config: doc, version });
  })
);

/** GET /admin/config/history — past changes, newest first. */
adminConfigRouter.get(
  '/history',
  asyncHandler(async (_req, res) => {
    const items = await prisma.adminAuditLog.findMany({
      where: { action: { startsWith: 'config.' } },
      orderBy: { createdAt: 'desc' },
      take: 50,
      include: { actor: { select: { id: true, fullName: true, email: true } } },
    });
    res.json({ items });
  })
);

/**
 * POST /admin/config/rollback/:auditId — put back the `before` of a change.
 *
 * Recorded as a new change rather than by deleting history, so the trail keeps
 * showing what happened and when it was undone.
 */
adminConfigRouter.post(
  '/rollback/:auditId',
  requirePermission('config.write'),
  asyncHandler(async (req, res) => {
    const entry = await prisma.adminAuditLog.findUnique({ where: { id: req.params.auditId } });
    if (!entry || !entry.action.startsWith('config.')) {
      throw new ApiError(404, 'Entrée de journal introuvable', 'NOT_FOUND');
    }
    if (!entry.before) throw new ApiError(400, 'Rien à restaurer', 'VALIDATION_FAILED');

    // `setConfig` deep-merges the snapshot into the current document and
    // validates the result, so a section reshaped since the entry was written
    // is caught there and rejected rather than stored in an unparseable form.
    const { doc, version, before } = await setConfig(entry.before, req.userId!);
    broadcastConfig(version);

    await audit(req, {
      action: 'config.rollback',
      targetType: 'config',
      targetId: entry.id,
      before,
      after: doc,
    });
    res.json({ config: doc, version });
  })
);
