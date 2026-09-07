import { Router } from 'express';
import { z } from 'zod';
import { prisma } from '../../lib/prisma';
import { asyncHandler } from '../../lib/http';
import { requirePermission } from '../../middleware/auth';
import { audit } from '../../lib/audit';
import { cacheBust } from '../../lib/cache';
import { bustConfigCache, configSnapshot, configVersionSnapshot } from '../../services/config';
import { bustMaintenanceCache } from '../../services/maintenance';
import { onlineCount, onlineUserIds } from '../../realtime/hub';
import { pushConfigured } from '../../services/push';
import { env } from '../../config/env';

/** Health, caches, counts and CSV exports. */
export const adminSystemRouter = Router();

/** GET /admin/system/health — is every dependency actually working. */
adminSystemRouter.get(
  '/health',
  asyncHandler(async (_req, res) => {
    const started = Date.now();
    let dbMs: number | null = null;
    let dbOk = false;
    try {
      const t = Date.now();
      await prisma.$queryRaw`SELECT 1`;
      dbMs = Date.now() - t;
      dbOk = true;
    } catch {
      dbOk = false;
    }

    res.json({
      db: { ok: dbOk, latencyMs: dbMs },
      push: { configured: pushConfigured() },
      cloudinary: { configured: !!env.cloudinary.cloudName },
      realtime: { sockets: onlineCount(), users: onlineUserIds().length },
      config: { version: configVersionSnapshot() },
      process: {
        uptimeSec: Math.round(process.uptime()),
        node: process.version,
        env: env.nodeEnv,
        memoryMb: Math.round(process.memoryUsage().rss / 1024 / 1024),
      },
      tookMs: Date.now() - started,
    });
  })
);

/** GET /admin/system/counts — row counts per table. */
adminSystemRouter.get(
  '/counts',
  asyncHandler(async (_req, res) => {
    const [
      users, owners, admins, listings, reviews, threads, messages,
      visits, reports, restrictions, auditLogs, devices, sessions,
    ] = await Promise.all([
      prisma.user.count(),
      prisma.user.count({ where: { isOwner: true } }),
      prisma.user.count({ where: { adminRole: { not: null } } }),
      prisma.listing.count(),
      prisma.review.count(),
      prisma.thread.count(),
      prisma.message.count(),
      prisma.visitRequest.count(),
      prisma.report.count(),
      prisma.userRestriction.count({ where: { revokedAt: null } }),
      prisma.adminAuditLog.count(),
      prisma.device.count(),
      prisma.appSession.count(),
    ]);
    res.json({
      users, owners, admins, listings, reviews, threads, messages,
      visits, reports, restrictions, auditLogs, devices, sessions,
    });
  })
);

/** POST /admin/system/cache/bust — drop a cache namespace. */
adminSystemRouter.post(
  '/cache/bust',
  requirePermission('system.write'),
  asyncHandler(async (req, res) => {
    const { target } = z
      .object({ target: z.enum(['listings', 'config', 'maintenance', 'all']) })
      .parse(req.body);

    if (target === 'listings' || target === 'all') cacheBust('listings:');
    if (target === 'config' || target === 'all') bustConfigCache();
    if (target === 'maintenance' || target === 'all') bustMaintenanceCache();
    // Restriction entries share the generic cache under a `restr:` prefix.
    if (target === 'all') cacheBust('restr:');

    await audit(req, { action: 'system.cacheBust', after: { target } });
    res.json({ ok: true, target });
  })
);

// ─────────────────────────────────────────────────────────────
// CSV exports
// ─────────────────────────────────────────────────────────────

/**
 * Render rows as CSV.
 *
 * Values are quoted and inner quotes doubled per RFC 4180. A leading `=`, `+`,
 * `-` or `@` is prefixed with an apostrophe: spreadsheet software treats those
 * as formulas, so an attacker-controlled field like a user's name could
 * otherwise execute when an operator opens the export.
 */
function toCsv(rows: Record<string, unknown>[]): string {
  if (!rows.length) return '';
  const headers = Object.keys(rows[0]);
  const cell = (v: unknown) => {
    if (v === null || v === undefined) return '';
    let s = v instanceof Date ? v.toISOString() : String(v);
    if (/^[=+\-@]/.test(s)) s = `'${s}`;
    return `"${s.replace(/"/g, '""')}"`;
  };
  return [
    headers.join(','),
    ...rows.map((r) => headers.map((h) => cell(r[h])).join(',')),
  ].join('\n');
}

function sendCsv(res: import('express').Response, name: string, rows: Record<string, unknown>[]) {
  res.setHeader('Content-Type', 'text/csv; charset=utf-8');
  res.setHeader('Content-Disposition', `attachment; filename="${name}"`);
  // BOM so Excel opens the accented French text as UTF-8 rather than mojibake.
  res.send('﻿' + toCsv(rows));
}

adminSystemRouter.get(
  '/export/users.csv',
  requirePermission('export.download'),
  asyncHandler(async (req, res) => {
    const rows = await prisma.user.findMany({
      select: {
        id: true, fullName: true, phone: true, email: true, city: true, region: true,
        isOwner: true, isActive: true, verified: true, identityVerified: true,
        membershipTier: true, adminRole: true, createdAt: true, lastSeenAt: true,
      },
      orderBy: { createdAt: 'desc' },
      take: 10_000,
    });
    await audit(req, { action: 'export.users', after: { rows: rows.length } });
    sendCsv(res, 'mobly-utilisateurs.csv', rows as Record<string, unknown>[]);
  })
);

adminSystemRouter.get(
  '/export/listings.csv',
  requirePermission('export.download'),
  asyncHandler(async (req, res) => {
    const rows = await prisma.listing.findMany({
      select: {
        id: true, title: true, category: true, deal: true, status: true,
        city: true, neighborhood: true, priceFcfa: true, rooms: true, furnished: true,
        verified: true, available: true, views: true, contacts: true, favorites: true,
        rating: true, reviewCount: true, ownerId: true, createdAt: true,
      },
      orderBy: { createdAt: 'desc' },
      take: 10_000,
    });
    await audit(req, { action: 'export.listings', after: { rows: rows.length } });
    sendCsv(res, 'mobly-annonces.csv', rows as Record<string, unknown>[]);
  })
);

adminSystemRouter.get(
  '/export/visits.csv',
  requirePermission('export.download'),
  asyncHandler(async (req, res) => {
    const rows = await prisma.visitRequest.findMany({
      select: {
        id: true, listingId: true, visitorId: true, ownerId: true,
        scheduledAt: true, status: true, createdAt: true,
      },
      orderBy: { createdAt: 'desc' },
      take: 10_000,
    });
    await audit(req, { action: 'export.visits', after: { rows: rows.length } });
    sendCsv(res, 'mobly-visites.csv', rows as Record<string, unknown>[]);
  })
);

adminSystemRouter.get(
  '/export/audit.csv',
  requirePermission('export.download'),
  asyncHandler(async (req, res) => {
    const rows = await prisma.adminAuditLog.findMany({
      select: {
        id: true, actorId: true, actorRole: true, action: true,
        targetType: true, targetId: true, ip: true, createdAt: true,
      },
      orderBy: { createdAt: 'desc' },
      take: 20_000,
    });
    await audit(req, { action: 'export.audit', after: { rows: rows.length } });
    sendCsv(res, 'mobly-audit.csv', rows as Record<string, unknown>[]);
  })
);
