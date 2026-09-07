/**
 * Seed realistic French reviews (avis) on every listing, then recompute each
 * listing's `rating` / `reviewCount` from those rows so the star rating the app
 * shows is exactly the average of the avis it displays.
 *
 *   npx tsx scripts/seed-reviews.ts            # only listings that have no avis yet
 *   npx tsx scripts/seed-reviews.ts --reset    # wipe seeded avis and regenerate
 *   npx tsx scripts/seed-reviews.ts --dry      # print what it would do
 *
 * Deterministic: the avis for a listing derive from its id, so re-running with
 * --reset produces the same set. Seeded rows are tagged with a trailing
 * zero-width marker in `text` so a reset never touches a real user's avis.
 */
import { prisma } from '../src/lib/prisma';

const MARKER = '​'; // zero-width space, invisible in the app
const RESET = process.argv.includes('--reset');
const DRY = process.argv.includes('--dry');

// ── deterministic RNG (mulberry32 seeded from the listing id) ────────────────
function hash(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}
function rng(seed: number) {
  let a = seed;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const pick = <T>(r: () => number, xs: T[]): T => xs[Math.floor(r() * xs.length)];

// ── avis texts, by star band ────────────────────────────────────────────────
const FIVE = [
  "Logement conforme aux photos, propre et bien situé. Le propriétaire est très réactif.",
  "Excellent séjour. Tout était prêt à mon arrivée, rien à redire.",
  "Très bon rapport qualité-prix pour le quartier. Je recommande vivement.",
  "Accueil chaleureux, visite rapide à organiser et aucune mauvaise surprise.",
  "Endroit calme, sécurisé et bien entretenu. J'y retournerais sans hésiter.",
  "Le propriétaire répond vite sur Mobly et a été honnête sur tout dès le départ.",
  "Vraiment satisfait. L'espace est encore mieux en vrai que sur les photos.",
  "Propreté impeccable et emplacement idéal pour se déplacer en ville.",
];
const FOUR = [
  "Bon logement dans l'ensemble, quelques détails à revoir mais rien de bloquant.",
  "Conforme à l'annonce. Un peu de bruit le soir, sinon très bien.",
  "Bien situé et propre. La connexion internet pourrait être plus stable.",
  "Séjour agréable, propriétaire correct. Je recommande.",
  "Correspond bien à la description. Petit manque de rangement, sinon parfait.",
  "Très bien pour le prix. Les coupures d'eau du quartier restent le seul souci.",
  "Rien à signaler de grave, expérience globalement positive.",
];
const THREE = [
  "Correct sans plus. L'annonce est honnête mais l'entretien laisse à désirer.",
  "Emplacement pratique, en revanche le logement mériterait un rafraîchissement.",
  "Ça dépanne bien, mais le prix me paraît un peu élevé pour ce que c'est.",
  "Le propriétaire met du temps à répondre. Le logement lui-même est convenable.",
];
const TWO = [
  "Décevant par rapport aux photos. Plusieurs choses n'étaient pas prêtes à l'arrivée.",
  "Quartier bruyant et entretien insuffisant. Je ne reprendrais pas.",
];
const BY_CATEGORY: Record<string, string[]> = {
  Appartements: ["Appartement spacieux et lumineux, parfait pour une famille."],
  Studios: ["Studio bien agencé, tout est à portée de main."],
  Chambres: ["Chambre propre et calme, idéale pour un séjour court."],
  Villas: ["Grande villa, cour sécurisée et beaucoup d'espace. Superbe."],
  Bureaux: ["Bureau fonctionnel, bonne connexion et cadre professionnel."],
};

function textFor(stars: number, category: string, r: () => number): string {
  if (stars === 5 && r() < 0.25 && BY_CATEGORY[category]) return pick(r, BY_CATEGORY[category]);
  if (stars === 5) return pick(r, FIVE);
  if (stars === 4) return pick(r, FOUR);
  if (stars === 3) return pick(r, THREE);
  return pick(r, TWO);
}

/** Realistic marketplace skew: mostly 5/4, a few 3, rarely 2. */
function starsFor(r: () => number): number {
  const x = r();
  if (x < 0.55) return 5;
  if (x < 0.85) return 4;
  if (x < 0.96) return 3;
  return 2;
}

async function main() {
  const listings = await prisma.listing.findMany({
    where: { archivedAt: null },
    select: { id: true, title: true, category: true, ownerId: true, createdAt: true },
  });
  const users = await prisma.user.findMany({
    where: { isActive: true, fullName: { not: '' } },
    select: { id: true },
  });
  if (users.length < 5) throw new Error('Not enough users to author avis.');

  console.log(`${listings.length} listings, ${users.length} possible authors${DRY ? ' (dry run)' : ''}`);

  if (RESET && !DRY) {
    const del = await prisma.review.deleteMany({ where: { text: { endsWith: MARKER } } });
    console.log(`Reset: removed ${del.count} previously seeded avis`);
  }

  let created = 0;
  let skipped = 0;

  for (const listing of listings) {
    const existing = await prisma.review.count({ where: { listingId: listing.id } });
    if (existing > 0) {
      skipped++;
      continue;
    }

    const r = rng(hash(listing.id));
    const count = 3 + Math.floor(r() * 10); // 3–12 avis

    // Authors: deterministic, unique per listing, never the owner.
    const pool = users.map((u) => u.id).filter((id) => id !== listing.ownerId);
    for (let i = pool.length - 1; i > 0; i--) {
      const j = Math.floor(r() * (i + 1));
      [pool[i], pool[j]] = [pool[j], pool[i]];
    }
    const authors = pool.slice(0, Math.min(count, pool.length));

    const now = Date.now();
    const floor = Math.max(listing.createdAt.getTime(), now - 300 * 86400_000);
    const rows = authors.map((userId) => {
      const stars = starsFor(r);
      const at = new Date(floor + r() * (now - floor));
      return {
        listingId: listing.id,
        userId,
        subjectId: listing.ownerId,
        rating: stars,
        text: textFor(stars, listing.category, r) + MARKER,
        createdAt: at,
        updatedAt: at,
      };
    });

    const avg = rows.reduce((s, x) => s + x.rating, 0) / rows.length;

    if (DRY) {
      console.log(`  ${listing.title.slice(0, 40).padEnd(42)} ${rows.length} avis → ${avg.toFixed(1)}★`);
      created += rows.length;
      continue;
    }

    await prisma.$transaction([
      prisma.review.createMany({ data: rows, skipDuplicates: true }),
      prisma.listing.update({
        where: { id: listing.id },
        data: { rating: Math.round(avg * 10) / 10, reviewCount: rows.length },
      }),
    ]);
    created += rows.length;
  }

  // Any listing that already had avis: make sure its rating still matches them.
  if (!DRY) {
    for (const listing of listings) {
      const agg = await prisma.review.aggregate({
        where: { listingId: listing.id },
        _avg: { rating: true },
        _count: true,
      });
      await prisma.listing.update({
        where: { id: listing.id },
        data: {
          rating: agg._avg.rating == null ? null : Math.round(agg._avg.rating * 10) / 10,
          reviewCount: agg._count,
        },
      });
    }
  }

  console.log(`Done — ${created} avis created, ${skipped} listings already had avis.`);
  await prisma.$disconnect();
}

main().catch(async (e) => {
  console.error(e);
  await prisma.$disconnect();
  process.exit(1);
});
