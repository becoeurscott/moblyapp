import { Prisma } from '@prisma/client';
import { prisma } from '../lib/prisma';
import { activeOwnerRelationWhere, ownerTrialEndsAt, OWNER_INSCRIPTION_FEE_FCFA } from '../lib/ownerTrial';
import { notifyUser } from './push';

/**
 * Automated notifications, one pass every 15 minutes, in process (same
 * pattern as the visit reminders).
 *
 * Rules every message follows:
 *  - sent once: each send claims a unique (userId, key) row in AutomationLog
 *    first, so overlapping runs or a restart never repeat one;
 *  - only between 08:00 and 21:00 Cameroon time;
 *  - the user's notification settings apply (notifyUser checks the type);
 *  - nudges (`promo`) are capped at 1 per day and 3 per week per user.
 *
 * AUTOMATIONS_DISABLED=1 turns the whole thing off.
 */

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;
const EVERY_MS = 15 * 60 * 1000;
const BATCH = 300;
/** Cameroon is UTC+1 all year. */
const CM_OFFSET = 1;

const fcfa = (n: number) => new Intl.NumberFormat('fr-FR').format(n) + ' FCFA';
const localHour = (now: Date) => (now.getUTCHours() + CM_OFFSET) % 24;
/** Calendar day in Cameroon, e.g. "2026-10-14". */
const localDay = (now: Date) => new Date(now.getTime() + CM_OFFSET * HOUR).toISOString().slice(0, 10);
/** The Monday of the current Cameroon week, as a day key. */
function localWeek(now: Date): string {
  const d = new Date(now.getTime() + CM_OFFSET * HOUR);
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 6) % 7));
  return d.toISOString().slice(0, 10);
}
/** Only events tagged with an app screen count, like the owner stats. */
const TRACKED = { source: { not: null } };

type Send = {
  userId: string;
  key: string;
  promo?: boolean;
  type: string;
  title: string;
  body: string;
  payload?: Record<string, string>;
};

/** Set by a dry run: collects what would be sent instead of sending. */
let preview: Send[] | null = null;

/** Claims the key, enforces the nudge cap, then sends. True when sent. */
async function sendOnce(s: Send, now: Date): Promise<boolean> {
  if (preview) {
    const already = await prisma.automationLog.count({ where: { userId: s.userId, key: s.key } });
    if (already === 0 && !preview.some((p) => p.userId === s.userId && p.key === s.key)) preview.push(s);
    return true;
  }
  if (s.promo) {
    const [today, week] = await Promise.all([
      prisma.automationLog.count({ where: { userId: s.userId, promo: true, createdAt: { gte: new Date(now.getTime() - DAY) } } }),
      prisma.automationLog.count({ where: { userId: s.userId, promo: true, createdAt: { gte: new Date(now.getTime() - 7 * DAY) } } }),
    ]);
    if (today >= 1 || week >= 3) return false;
  }
  try {
    await prisma.automationLog.create({ data: { userId: s.userId, key: s.key, promo: !!s.promo } });
  } catch (err) {
    if (err instanceof Prisma.PrismaClientKnownRequestError && err.code === 'P2002') return false;
    throw err;
  }
  await notifyUser({ userId: s.userId, type: s.type, title: s.title, body: s.body, payload: s.payload })
    .catch((err) => console.error('[automations] notify failed', s.key, err));
  return true;
}

/** Keys already used, so a pass skips them without a write. */
async function usedKeys(keys: string[]): Promise<Set<string>> {
  if (keys.length === 0) return new Set();
  const rows = await prisma.automationLog.findMany({ where: { key: { in: keys } }, select: { userId: true, key: true } });
  return new Set(rows.map((r) => `${r.userId}|${r.key}`));
}

// ─── Owners ──────────────────────────────────────────────────────────────

/** Trial ends in 2 days, ends today, has ended (within 3 days). */
async function ownerTrial(now: Date): Promise<number> {
  const owners = await prisma.user.findMany({
    where: {
      isOwner: true, ownerPaid: false, isActive: true,
      ownerTrialStartedAt: { gte: new Date(now.getTime() - 10 * DAY) },
    },
    select: { id: true, ownerTrialStartedAt: true },
    take: BATCH,
  });
  let sent = 0;
  const fee = fcfa(OWNER_INSCRIPTION_FEE_FCFA);
  for (const o of owners) {
    const ends = ownerTrialEndsAt(o.ownerTrialStartedAt);
    if (!ends) continue;
    const left = ends.getTime() - now.getTime();
    const start = o.ownerTrialStartedAt!.getTime();
    let msg: { key: string; title: string; body: string } | null = null;
    if (left > DAY && left <= 2 * DAY) {
      msg = { key: `trial:2d:${start}`, title: 'Votre essai se termine dans 2 jours',
        body: `Activez votre compte propriétaire (${fee}, une seule fois) pour garder vos annonces en ligne.` };
    } else if (left > 0 && left <= DAY) {
      msg = { key: `trial:last:${start}`, title: 'Dernier jour de votre essai gratuit',
        body: `Demain vos annonces seront masquées. Activez votre compte pour ${fee}.` };
    } else if (left <= 0 && left > -3 * DAY) {
      msg = { key: `trial:ended:${start}`, title: 'Vos annonces sont masquées',
        body: `Votre essai est terminé. Activez votre compte (${fee}) pour les remettre en ligne.` };
    }
    if (msg && await sendOnce({ userId: o.id, type: 'OWNER_TRIAL', payload: { action: 'become_owner' }, ...msg }, now)) sent++;
  }
  return sent;
}

/** A prospect's message the owner hasn't answered after 2 h, then 24 h. */
async function unansweredMessages(now: Date): Promise<number> {
  // Latest message per thread, among threads about an annonce, last 72 h.
  const rows = await prisma.$queryRaw<{ id: string; threadId: string; senderId: string; createdAt: Date; ownerId: string; title: string; senderName: string | null }[]>`
    SELECT DISTINCT ON (m."threadId") m.id, m."threadId", m."senderId", m."createdAt",
           l."ownerId", l.title, u."fullName" AS "senderName"
    FROM "Message" m
    JOIN "Thread" t ON t.id = m."threadId"
    JOIN "Listing" l ON l.id = t."listingId"
    JOIN "User" u ON u.id = m."senderId"
    WHERE m."createdAt" >= ${new Date(now.getTime() - 72 * HOUR)}
      AND m.kind <> 'SYSTEM'
    ORDER BY m."threadId", m."createdAt" DESC`;
  let sent = 0;
  for (const r of rows) {
    if (r.senderId === r.ownerId) continue; // the owner spoke last: answered
    const age = now.getTime() - new Date(r.createdAt).getTime();
    const name = r.senderName?.trim() || 'Un client';
    let msg: { key: string; title: string; body: string } | null = null;
    if (age >= 24 * HOUR) {
      msg = { key: `unanswered:24h:${r.id}`, title: `${name} attend toujours votre réponse`,
        body: `Message sans réponse depuis hier à propos de « ${r.title} ». Répondez pour ne pas perdre ce client.` };
    } else if (age >= 2 * HOUR) {
      msg = { key: `unanswered:2h:${r.id}`, title: `${name} attend votre réponse`,
        body: `Nouveau message à propos de « ${r.title} ». Les propriétaires qui répondent vite louent plus vite.` };
    }
    if (msg && await sendOnce({ userId: r.ownerId, type: 'MESSAGE', payload: { threadId: r.threadId }, ...msg }, now)) sent++;
  }
  return sent;
}

/** Monday from 09:00: the past week's impressions, clicks and contacts. */
async function weeklySummary(now: Date): Promise<number> {
  const d = new Date(now.getTime() + CM_OFFSET * HOUR);
  if (d.getUTCDay() !== 1 || localHour(now) < 9) return 0;
  const week = localWeek(now);
  const since = new Date(now.getTime() - 7 * DAY);
  const owners = await prisma.user.findMany({
    where: { isOwner: true, isActive: true, ...activeOwnerRelationWhere(), listings: { some: {} } },
    select: { id: true },
    take: 1000,
  });
  const used = await usedKeys([`weekly:${week}`]);
  let sent = 0;
  for (const o of owners) {
    if (used.has(`${o.id}|weekly:${week}`)) continue;
    const mine = { listing: { ownerId: o.id }, createdAt: { gte: since } };
    const [imp, clk, con] = await Promise.all([
      prisma.impressionEvent.count({ where: { ...mine, ...TRACKED } }),
      prisma.viewEvent.count({ where: { ...mine, ...TRACKED } }),
      prisma.contactEvent.count({ where: mine }),
    ]);
    if (imp + clk + con === 0) continue;
    if (await sendOnce({
      userId: o.id, key: `weekly:${week}`, type: 'OWNER_STATS',
      title: 'Votre semaine sur Mobly 📊',
      body: `${imp} impressions, ${clk} clics et ${con} contact${con > 1 ? 's' : ''} sur vos annonces ces 7 derniers jours.`,
      payload: { action: 'become_owner' },
    }, now)) sent++;
  }
  return sent;
}

/** An annonce seen a lot but rarely opened: suggest better photos / price. */
async function weakListingTips(now: Date): Promise<number> {
  const since = new Date(now.getTime() - 7 * DAY);
  const shown = await prisma.impressionEvent.groupBy({
    by: ['listingId'],
    where: { ...TRACKED, createdAt: { gte: since } },
    _count: { _all: true },
    having: { listingId: { _count: { gte: 30 } } },
  });
  if (shown.length === 0) return 0;
  const clicks = await prisma.viewEvent.groupBy({
    by: ['listingId'],
    where: { ...TRACKED, createdAt: { gte: since }, listingId: { in: shown.map((s) => s.listingId) } },
    _count: { _all: true },
  });
  const clicksBy = new Map(clicks.map((c) => [c.listingId, c._count._all]));
  const fortnight = Math.floor(now.getTime() / (14 * DAY));
  let sent = 0;
  for (const s of shown) {
    const imp = s._count._all;
    const clk = clicksBy.get(s.listingId) ?? 0;
    if (clk / imp >= 0.03) continue; // under 3% of people who see it open it
    const l = await prisma.listing.findUnique({
      where: { id: s.listingId },
      select: { id: true, title: true, ownerId: true, status: true, createdAt: true },
    });
    if (!l || !['ACTIVE', 'BOOSTED'].includes(l.status) || now.getTime() - l.createdAt.getTime() < 7 * DAY) continue;
    if (await sendOnce({
      userId: l.ownerId, key: `tip:${l.id}:${fortnight}`, promo: true, type: 'OWNER_TIP',
      title: `« ${l.title} » est vue mais peu ouverte`,
      body: `${imp} personnes l'ont vue cette semaine, ${clk} l'ont ouverte. Une photo de couverture plus lumineuse ou un prix ajusté peut tout changer.`,
      payload: { action: 'become_owner' },
    }, now)) sent++;
  }
  return sent;
}

/** Owners whose identity isn't verified: their annonces can't go live. */
async function identityReminder(now: Date): Promise<number> {
  const owners = await prisma.user.findMany({
    where: { isOwner: true, isActive: true, identityVerified: false,
      createdAt: { lte: new Date(now.getTime() - DAY), gte: new Date(now.getTime() - 30 * DAY) } },
    select: { id: true, createdAt: true, _count: { select: { listings: { where: { status: 'PENDING' } } } } },
    take: BATCH,
  });
  let sent = 0;
  for (const o of owners) {
    const age = now.getTime() - o.createdAt.getTime();
    const step = age >= 7 * DAY ? 3 : age >= 3 * DAY ? 2 : 1;
    const pending = o._count.listings;
    if (await sendOnce({
      userId: o.id, key: `identity:${step}`, type: 'IDENTITY',
      title: pending > 0 ? `${pending} annonce${pending > 1 ? 's attendent' : ' attend'} votre vérification` : 'Vérifiez votre identité',
      body: 'Vérifiez votre identité en 2 minutes : vos annonces seront publiées automatiquement.',
      payload: { action: 'become_owner' },
    }, now)) sent++;
  }
  return sent;
}

// ─── Renters ─────────────────────────────────────────────────────────────

/**
 * From 09:00, once a day: the best new annonce (last 24 h) for each user,
 * matched on their saved search preferences (type, region, budget) or, when
 * they have none, on their city — "près de vous".
 */
async function dailyMatches(now: Date): Promise<number> {
  if (localHour(now) < 9) return 0;
  const day = localDay(now);
  const fresh = await prisma.listing.findMany({
    where: { status: { in: ['ACTIVE', 'BOOSTED'] }, available: true, createdAt: { gte: new Date(now.getTime() - DAY) },
      owner: activeOwnerRelationWhere() },
    select: { id: true, title: true, category: true, region: true, city: true, neighborhood: true, priceFcfa: true, ownerId: true, status: true },
    orderBy: { createdAt: 'desc' },
    take: 200,
  });
  if (fresh.length === 0) return 0;
  const users = await prisma.user.findMany({
    where: { isActive: true, devices: { some: { pushToken: { not: null } } },
      OR: [{ searchPreference: { isNot: null } }, { city: { not: null } }] },
    select: { id: true, city: true, region: true, searchPreference: true },
    take: 2000,
  });
  const used = await usedKeys([`matches:${day}`]);
  let sent = 0;
  for (const u of users) {
    if (used.has(`${u.id}|matches:${day}`)) continue;
    const pref = u.searchPreference;
    const region = pref?.region ?? u.region;
    const matches = fresh.filter((l) => {
      if (l.ownerId === u.id) return false;
      const place = u.city ? l.city === u.city || (!!region && l.region === region) : !!region && l.region === region;
      if (!place) return false;
      if (pref?.spaceTypes.length && !pref.spaceTypes.includes(l.category)) return false;
      if (pref?.budgetMax && l.priceFcfa > pref.budgetMax) return false;
      if (pref?.budgetMin && l.priceFcfa < pref.budgetMin) return false;
      return true;
    });
    if (matches.length === 0) continue;
    // Same city first, boosted first within that.
    matches.sort((a, b) => Number(b.city === u.city) - Number(a.city === u.city)
      || Number(b.status === 'BOOSTED') - Number(a.status === 'BOOSTED'));
    const top = matches[0];
    const where = top.neighborhood ? `${top.neighborhood}, ${top.city}` : top.city;
    const more = matches.length > 1 ? ` et ${matches.length - 1} autre${matches.length > 2 ? 's' : ''}` : '';
    if (await sendOnce({
      userId: u.id, key: `matches:${day}`, type: 'NEW_LISTING',
      title: pref ? 'Nous avons trouvé un espace pour vous 🏠' : 'Nous avons trouvé un espace près de vous 🏠',
      body: `${top.title} à ${where}, ${fcfa(top.priceFcfa)}${more}. Basé sur ${pref ? 'vos préférences' : 'votre localisation'}.`,
      payload: { listingId: top.id },
    }, now)) sent++;
  }
  return sent;
}

/** A saved annonce got cheaper. */
async function favoritePriceDrops(now: Date): Promise<number> {
  const dropped = await prisma.listing.findMany({
    where: { priceDroppedAt: { gte: new Date(now.getTime() - 2 * DAY) }, previousPriceFcfa: { not: null },
      status: { in: ['ACTIVE', 'BOOSTED'] }, available: true },
    select: { id: true, title: true, priceFcfa: true, previousPriceFcfa: true,
      favoritedBy: { select: { userId: true }, take: 1000 } },
    take: 100,
  });
  let sent = 0;
  for (const l of dropped) {
    for (const f of l.favoritedBy) {
      if (await sendOnce({
        userId: f.userId, key: `pricedrop:${l.id}:${l.priceFcfa}`, type: 'PRICE_DROP',
        title: 'Baisse de prix sur un favori 📉',
        body: `${l.title} passe de ${fcfa(l.previousPriceFcfa!)} à ${fcfa(l.priceFcfa)}.`,
        payload: { listingId: l.id },
      }, now)) sent++;
    }
  }
  return sent;
}

/** Opened an annonce 2+ times, 1 to 3 days ago, and never wrote to the owner. */
async function interestWithoutContact(now: Date): Promise<number> {
  const rows = await prisma.$queryRaw<{ userId: string; listingId: string; title: string }[]>`
    SELECT ve."userId", ve."listingId", l.title
    FROM "ViewEvent" ve
    JOIN "Listing" l ON l.id = ve."listingId"
    WHERE ve."userId" IS NOT NULL AND ve.source IS NOT NULL
      AND ve."createdAt" >= ${new Date(now.getTime() - 3 * DAY)}
      AND l.status IN ('ACTIVE', 'BOOSTED') AND l.available = true
      AND l."ownerId" <> ve."userId"
      AND NOT EXISTS (SELECT 1 FROM "ContactEvent" ce WHERE ce."listingId" = l.id AND ce."visitorId" = ve."userId")
      AND NOT EXISTS (SELECT 1 FROM "Thread" t JOIN "ThreadParticipant" tp ON tp."threadId" = t.id
                      WHERE t."listingId" = l.id AND tp."userId" = ve."userId")
    GROUP BY ve."userId", ve."listingId", l.title
    HAVING COUNT(*) >= 2 AND MAX(ve."createdAt") <= ${new Date(now.getTime() - DAY)}
    LIMIT ${BATCH}`;
  let sent = 0;
  for (const r of rows) {
    if (await sendOnce({
      userId: r.userId, key: `interest:${r.listingId}`, promo: true, type: 'REMINDER',
      title: 'Cet espace vous intéresse ?',
      body: `« ${r.title} » est toujours disponible. Écrivez au propriétaire avant qu'il ne soit loué.`,
      payload: { listingId: r.listingId },
    }, now)) sent++;
  }
  return sent;
}

/** 3 to 48 hours after a visit: ask for a review. */
async function reviewAfterVisit(now: Date): Promise<number> {
  const visits = await prisma.visitRequest.findMany({
    where: { status: { in: ['CONFIRMED', 'COMPLETED'] },
      scheduledAt: { gte: new Date(now.getTime() - 48 * HOUR), lte: new Date(now.getTime() - 3 * HOUR) } },
    select: { id: true, visitorId: true, listingId: true, listing: { select: { title: true } } },
    take: BATCH,
  });
  let sent = 0;
  for (const v of visits) {
    const reviewed = await prisma.review.count({ where: { listingId: v.listingId, userId: v.visitorId } });
    if (reviewed > 0) continue;
    if (await sendOnce({
      userId: v.visitorId, key: `review:${v.id}`, type: 'VISIT_REVIEW',
      title: 'Comment s\'est passée la visite ?',
      body: `Donnez votre avis sur « ${v.listing.title} » : il aidera les prochains visiteurs.`,
      payload: { listingId: v.listingId },
    }, now)) sent++;
  }
  return sent;
}

// ─── Runner ──────────────────────────────────────────────────────────────

/** What a pass would send right now, without sending or recording anything. */
export async function previewAutomations(now = new Date()): Promise<Send[]> {
  preview = [];
  try {
    await runAutomations(now, true);
    return preview;
  } finally {
    preview = null;
  }
}

/** One pass. Exported for scripts and tests. */
export async function runAutomations(now = new Date(), ignoreQuietHours = false): Promise<Record<string, number>> {
  const h = localHour(now);
  if (!ignoreQuietHours && (h < 8 || h >= 21)) return {};
  const result: Record<string, number> = {};
  const rules: [string, (n: Date) => Promise<number>][] = [
    ['ownerTrial', ownerTrial], ['unanswered', unansweredMessages], ['weekly', weeklySummary],
    ['tips', weakListingTips], ['identity', identityReminder], ['matches', dailyMatches],
    ['priceDrops', favoritePriceDrops], ['interest', interestWithoutContact], ['reviews', reviewAfterVisit],
  ];
  for (const [name, rule] of rules) {
    try {
      result[name] = await rule(now);
    } catch (err) {
      console.error(`[automations] ${name} failed:`, err);
    }
  }
  return result;
}

let running = false;

export function startAutomations() {
  if (process.env.AUTOMATIONS_DISABLED === '1') return;
  const run = async () => {
    if (running) return;
    running = true;
    try {
      const r = await runAutomations();
      const total = Object.values(r).reduce((a, b) => a + b, 0);
      if (total > 0) console.log('[automations] sent', JSON.stringify(r));
    } finally {
      running = false;
    }
  };
  setTimeout(run, 60_000).unref();
  setInterval(run, EVERY_MS).unref();
}
