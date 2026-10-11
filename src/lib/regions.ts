import type { Prisma } from '@prisma/client';

/**
 * Listing rows spell a région many ways — "Littoral", "Littoral Region",
 * "Région du Littoral", or in English ("South", "Southwest Region"), depending
 * on whether it came from the publish wizard, an import, or the geocoder. An
 * exact match on the canonical name found only a fraction of them.
 *
 * Each canonical French name maps to its English name; every spelling below
 * is matched case-insensitively. Exact values only: a `contains` on "Nord"
 * would also catch "Nord-Ouest" and "Extrême-Nord".
 */
const REGION_NAMES: Record<string, { en: string[]; fr: string }> = {
  Littoral: { fr: 'du Littoral', en: ['Littoral'] },
  Centre: { fr: 'du Centre', en: ['Centre', 'Center'] },
  Ouest: { fr: "de l'Ouest", en: ['West'] },
  'Sud-Ouest': { fr: 'du Sud-Ouest', en: ['Southwest', 'South-West', 'South West'] },
  'Nord-Ouest': { fr: 'du Nord-Ouest', en: ['Northwest', 'North-West', 'North West'] },
  Sud: { fr: 'du Sud', en: ['South'] },
  Est: { fr: "de l'Est", en: ['East'] },
  Adamaoua: { fr: "de l'Adamaoua", en: ['Adamawa', 'Adamaoua'] },
  Nord: { fr: 'du Nord', en: ['North'] },
  'Extrême-Nord': { fr: "de l'Extrême-Nord", en: ['Far North', 'Far-North', 'Extreme North', 'Extreme-North'] },
};

export function regionSpellings(region: string): string[] {
  const entry = REGION_NAMES[region];
  if (!entry) return [region];
  const names = new Set<string>([region, `Région ${entry.fr}`, `${region} Region`]);
  for (const en of entry.en) {
    names.add(en);
    names.add(`${en} Region`);
  }
  return [...names];
}

/** `where` clause matching every spelling of a région on `Listing.region`. */
export function regionWhere(region: string): Prisma.ListingWhereInput {
  return {
    OR: regionSpellings(region).map((name) => ({
      region: { equals: name, mode: 'insensitive' as const },
    })),
  };
}
