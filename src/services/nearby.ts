import { Prisma } from '@prisma/client';
import { prisma } from '../lib/prisma';
import { serializeListing } from '../lib/serialize';

/** Boosted annonces within this distance lead a "near me" ranking. */
export const BOOST_NEAR_KM = 25;

function distanceKm(a: { lat: number; lng: number }, b: { lat: number; lng: number }): number {
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLng = (b.lng - a.lng) * rad;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 6371 * 2 * Math.asin(Math.min(1, Math.sqrt(h)));
}

/**
 * "Près de vous": every matching annonce ranked by distance from `origin`,
 * boosted ones within BOOST_NEAR_KM first (a boost bought in Yaoundé must not
 * lead the list for someone in Douala), then everything else nearest-first,
 * annonces without coordinates last.
 *
 * Ranks on a light id+position scan of the whole set (≈1.3k rows), then loads
 * full rows for the requested page only — Prisma can't ORDER BY a computed
 * distance, and the app pages through only the first few dozen.
 */
export async function nearestListings<L extends Parameters<typeof serializeListing>[0]>(
  where: Prisma.ListingWhereInput,
  origin: { lat: number; lng: number },
  offset: number,
  limit: number,
  /** Loads full rows (with the owner fields the caller serializes) by id. */
  load: (ids: string[]) => Promise<(L & { id: string })[]>
) {
  const rows = await prisma.listing.findMany({
    where,
    select: { id: true, lat: true, lng: true, status: true },
  });
  const ranked = rows
    .map((r) => {
      const km = r.lat != null && r.lng != null ? distanceKm(origin, { lat: r.lat, lng: r.lng }) : null;
      const boostedNear = r.status === 'BOOSTED' && km != null && km <= BOOST_NEAR_KM;
      return { id: r.id, km, boostedNear };
    })
    .sort((a, b) => {
      if (a.boostedNear !== b.boostedNear) return a.boostedNear ? -1 : 1;
      if (a.km == null || b.km == null) return a.km == null ? (b.km == null ? 0 : 1) : -1;
      return a.km - b.km;
    });

  const page = ranked.slice(offset, offset + limit);
  const full = await load(page.map((p) => p.id));
  const byId = new Map(full.map((l) => [l.id, l]));
  const items = page.flatMap((p) => {
    const l = byId.get(p.id);
    if (!l) return [];
    return [{ ...serializeListing(l), distanceKm: p.km == null ? null : Math.round(p.km * 10) / 10 }];
  });
  return { total: rows.length, items };
}

