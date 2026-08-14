/**
 * One-shot importer: reads the Airbnb scraper JSON, keeps Cameroon-only
 * listings, and upserts them into the Supabase database.
 *
 * Run:
 *   export PATH="$HOME/.local/node-v22.23.1-darwin-arm64/bin:$PATH"
 *   cd backend && npx tsx src/lib/import-airbnb.ts
 *
 * Idempotent: imported listings carry the tag "airbnb-import"; they are
 * deleted and re-inserted on each run so you can safely re-run after edits.
 */

import { PrismaClient, DealType, PriceUnit, ListingStatus } from '@prisma/client';
import * as fs from 'fs';
import * as path from 'path';

const prisma = new PrismaClient();

// ─── Types ────────────────────────────────────────────────────────────────────

interface AirbnbRecord {
  id: string;
  coordinates?: { latitude: number; longitude: number };
  propertyType?: string;
  personCapacity?: number;
  rating?: {
    guestSatisfaction?: number;
    reviewsCount?: number;
    accuracy?: number;
  };
  host?: {
    id: string;
    name: string;
    profileImage?: string;
    isSuperHost?: boolean;
    isVerified?: boolean;
    ratingAverage?: number;
  };
  locationSubtitle?: string;
  title?: string;
  description?: string;
  price?: {
    price?: string;
    breakDown?: {
      basePrice?: {
        description?: string; // "5 nights x $52.69"
      };
    };
  };
  images?: Array<{ imageUrl: string; caption?: string }>;
  thumbnail?: string;
  amenities?: Array<{
    title: string;
    values: Array<{ title: string; available: boolean }>;
  }>;
  sharingConfigTitle?: string; // "Apt in Douala · ★4.9 · 2 bedrooms · 2 beds"
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function mapCategory(propertyType: string): string {
  const t = (propertyType ?? '').toLowerCase();
  if (t.includes('villa') || t.includes('vacation home') || t.includes('castle')) return 'Villas';
  if (
    t.includes('private room') ||
    t.includes('room in hotel') ||
    t.includes('room in guesthouse') ||
    t.includes('room in condo') ||
    t.includes('room in rental') ||
    t.includes('room in bed')
  )
    return 'Chambres';
  if (
    t.includes('cabin') ||
    t.includes('cottage') ||
    t.includes('tiny') ||
    t.includes('treehouse') ||
    t.includes('tent') ||
    t.includes('guest suite') ||
    t.includes('guesthouse')
  )
    return 'Studios';
  // Default bucket: apartments, condos, homes, rental units, townhouses
  return 'Appartements';
}

/** Parse per-night USD from "5 nights x $52.69" → FCFA (rounded to 500). */
function parsePricePerNightFcfa(record: AirbnbRecord): number {
  const USD_TO_FCFA = 600;
  const bp = record.price?.breakDown?.basePrice?.description ?? '';
  const match = bp.match(/x \$([0-9,.]+)/);
  if (match) {
    const usd = parseFloat(match[1].replace(/,/g, ''));
    return Math.max(5000, Math.round((usd * USD_TO_FCFA) / 500) * 500);
  }
  // Fallback: assume total price is for ~5 nights
  const raw = (record.price?.price ?? '$30').replace(/[$,]/g, '');
  const usd = parseFloat(raw) || 30;
  return Math.max(5000, Math.round((usd * USD_TO_FCFA) / 5 / 500) * 500);
}

/** Parse bedroom count from "· 2 bedrooms ·" or "· 1 bedroom ·". */
function parseRooms(record: AirbnbRecord): number {
  const st = record.sharingConfigTitle ?? '';
  const m = st.match(/(\d+)\s+bedroom/);
  return m ? parseInt(m[1], 10) : 1;
}

/** Extract usable tags from Airbnb amenities. */
const AMENITY_MAP: Record<string, string> = {
  wifi: 'Wifi',
  television: 'TV',
  tv: 'TV',
  'air conditioning': 'Climatisation',
  kitchen: 'Cuisine équipée',
  'free parking': 'Parking',
  parking: 'Parking',
  pool: 'Piscine',
  gym: 'Salle de sport',
  washer: 'Lave-linge',
  breakfast: 'Petit-déjeuner',
  security: 'Sécurité',
  'hot water': 'Eau chaude',
  shampoo: 'Produits de toilette',
  'first aid': 'Trousse de secours',
};

function extractTags(amenities: AirbnbRecord['amenities']): string[] {
  if (!amenities?.length) return [];
  const tags = new Set<string>();
  for (const group of amenities) {
    for (const item of group.values ?? []) {
      if (!item.available) continue;
      const key = item.title.toLowerCase();
      for (const [fragment, label] of Object.entries(AMENITY_MAP)) {
        if (key.includes(fragment)) {
          tags.add(label);
          break;
        }
      }
    }
  }
  return [...tags].slice(0, 8);
}

/** "Douala, Littoral Region, Cameroon" → { city, region } */
function parseLocation(subtitle: string): { city: string; region: string } {
  const parts = subtitle.split(',').map((s) => s.trim());
  return {
    city: parts[0] ?? 'Douala',
    region: parts[1] ?? 'Littoral',
  };
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const dataPath = path.join(__dirname, 'dataset_airbnb-scraper_2026-07-26_13-29-06-779.json');
  const raw: AirbnbRecord[] = JSON.parse(fs.readFileSync(dataPath, 'utf8'));

  // Cameroon only
  const records = raw.filter((r) => r.locationSubtitle?.includes('Cameroon'));
  console.log(`Found ${records.length} Cameroon listings out of ${raw.length} total`);

  // ── 1. Clear previous import ────────────────────────────────────────────────
  const deleted = await prisma.listing.deleteMany({ where: { tags: { has: 'airbnb-import' } } });
  if (deleted.count > 0) console.log(`Removed ${deleted.count} previously imported listings`);

  // ── 2. Upsert one User per unique Airbnb host ───────────────────────────────
  const hostMap = new Map<string, string>(); // airbnbHostId → prisma userId

  const uniqueHosts = [...new Map(records.map((r) => [r.host?.id, r.host])).values()].filter(Boolean) as NonNullable<AirbnbRecord['host']>[];

  console.log(`Upserting ${uniqueHosts.length} host users…`);
  for (const h of uniqueHosts) {
    // Synthetic Cameroonian phone derived from the Airbnb host ID
    const phone = `+2376${h.id.slice(-8)}`;
    const user = await prisma.user.upsert({
      where: { phone },
      update: {
        fullName: h.name,
        avatarUrl: h.profileImage ?? null,
        verified: h.isVerified ?? false,
        rating: h.ratingAverage ?? null,
        isOwner: true,
      },
      create: {
        phone,
        fullName: h.name,
        avatarUrl: h.profileImage ?? null,
        verified: h.isVerified ?? false,
        rating: h.ratingAverage ?? null,
        isOwner: true,
      },
    });
    hostMap.set(h.id, user.id);
  }

  // ── 3. Insert listings ──────────────────────────────────────────────────────
  console.log(`Importing ${records.length} listings…`);
  let ok = 0;
  let skip = 0;

  for (const rec of records) {
    const ownerId = hostMap.get(rec.host?.id ?? '');
    if (!ownerId) { skip++; continue; }

    const { city, region } = parseLocation(rec.locationSubtitle ?? '');
    const category = mapCategory(rec.propertyType ?? '');
    const priceFcfa = parsePricePerNightFcfa(rec);
    const rooms = parseRooms(rec);
    const tags = ['airbnb-import', ...extractTags(rec.amenities)];
    const photos = (rec.images ?? []).map((i) => i.imageUrl).slice(0, 12);
    const rating = rec.rating?.guestSatisfaction ?? null;
    const reviewCount = rec.rating?.reviewsCount ?? 0;

    // Category-specific features
    const features: Record<string, string> = {
      Personnes: String(rec.personCapacity ?? 2),
    };
    if (rooms > 0) features['Chambres'] = String(rooms);

    await prisma.listing.create({
      data: {
        ownerId,
        title: rec.title ?? 'Logement à louer',
        category,
        deal: DealType.SHORT,
        priceUnit: PriceUnit.PER_DAY,
        status: ListingStatus.ACTIVE,
        city,
        region,
        lat: rec.coordinates?.latitude ?? null,
        lng: rec.coordinates?.longitude ?? null,
        priceFcfa,
        furnished: true,
        rooms,
        about: rec.description?.slice(0, 1000) ?? '',
        tags,
        coverUrl: rec.thumbnail ?? null,
        photos,
        features,
        rating,
        reviewCount,
        verified: true,
        available: true,
      },
    });
    ok++;
  }

  console.log(`✅ Imported ${ok} listings (skipped ${skip} with missing host)`);
}

main()
  .catch((e) => { console.error(e); process.exit(1); })
  .finally(() => prisma.$disconnect());
