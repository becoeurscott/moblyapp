import { z } from 'zod';

/**
 * The remotely-controlled configuration of the whole product.
 *
 * Every value here was once a constant in the code. Moving them into one
 * validated document is what lets the dashboard change how the app behaves
 * without a deploy — and, just as importantly, what lets an operator undo a
 * bad change in seconds.
 *
 * Two rules keep this safe:
 *
 * 1. **Every field has a default equal to today's hardcoded behaviour.** An
 *    empty `AppConfig` row therefore describes the app exactly as it shipped,
 *    so a missing row, a failed read, or a half-written document can never
 *    brick the product. Parsing `{}` yields a complete, working config.
 * 2. **Defaults are permissive, not restrictive.** Flags default to `true`,
 *    allowlists default to empty (= "no restriction"). A config that fails to
 *    load must never lock users out; the failure mode is "everything works",
 *    never "nothing works".
 *
 * `security` and `moderation` never leave the admin API — see `toPublicConfig`.
 */

/** A feature switch plus the French sentence shown when it is off. */
const flag = (enabled = true, message?: string) =>
  z
    .object({
      enabled: z.boolean().default(enabled),
      /// Shown verbatim to the user. Null = the app's generic wording.
      message: z.string().max(300).nullish().default(message ?? null),
    })
    .default({});

/**
 * Max requests per window for one limiter.
 *
 * Only the ceiling is configurable, not the window: `express-rate-limit`
 * re-evaluates a function-valued `limit` on every request but takes `windowMs`
 * once at construction, so a configurable window would look adjustable in the
 * dashboard and silently do nothing. Every window stays at 15 minutes —
 * `RATE_LIMIT_WINDOW_MS` below.
 */
const maxPerWindow = (limit: number) =>
  z.number().int().min(1).max(100_000).default(limit);

const QUARTIERS_DEFAULT: Record<string, string[]> = {
  Douala: ['Akwa', 'Bonapriso', 'Bonanjo', 'Bali', 'Deido', 'Bonamoussadi', 'Makepe', 'Bonabéri', 'New Bell', 'Ndokotti', 'Logbessou', 'Kotto'],
  Yaoundé: ['Bastos', 'Nlongkak', 'Essos', 'Nsam', 'Mvog-Mbi', 'Nsimeyong', 'Biyem-Assi', 'Mendong', 'Odza', 'Ekounou'],
  Bafoussam: ['Tamdja', 'Kamkop', 'Djeleng', 'Tougang', 'Banengo', 'Famla'],
  Kribi: ['Dombé', 'Mpangou', 'Talla', 'Afan-Mabé', 'Bwambé'],
  Limbé: ['Down Beach', 'Bota', 'Mile 4', 'Church Street', 'New Town'],
  Buéa: ['Molyko', 'Great Soppo', 'Bonduma', 'Bomaka', 'Mile 16', 'Muea'],
};

const REGIONS_DEFAULT = [
  { name: 'Littoral', cities: ['Douala', 'Nkongsamba', 'Édéa', 'Loum', 'Manjo', 'Mbanga'] },
  { name: 'Centre', cities: ['Yaoundé', 'Mbalmayo', 'Obala', 'Bafia', 'Nanga-Eboko', 'Akonolinga'] },
  { name: 'Ouest', cities: ['Bafoussam', 'Dschang', 'Foumban', 'Mbouda', 'Bandjoun', 'Bafang'] },
  { name: 'Sud-Ouest', cities: ['Buéa', 'Limbé', 'Kumba', 'Tiko', 'Mamfe', 'Mutengene'] },
  { name: 'Nord-Ouest', cities: ['Bamenda', 'Kumbo', 'Ndop', 'Wum', 'Fundong', 'Bali'] },
  { name: 'Sud', cities: ['Ebolowa', 'Kribi', 'Sangmélima', 'Ambam', 'Djoum'] },
  { name: 'Est', cities: ['Bertoua', 'Batouri', 'Abong-Mbang', 'Yokadouma', 'Bélabo'] },
  { name: 'Adamaoua', cities: ['Ngaoundéré', 'Meiganga', 'Tibati', 'Banyo', 'Tignère'] },
  { name: 'Nord', cities: ['Garoua', 'Guider', 'Figuil', 'Poli', 'Lagdo'] },
  { name: 'Extrême-Nord', cities: ['Maroua', 'Kousséri', 'Mokolo', 'Yagoua', 'Kaélé'] },
];

const CATEGORIES_DEFAULT = [
  'Chambres', 'Studios', 'Appartements', 'Villas',
  'Bureaux', 'Boutiques', 'Coworking', 'Commercial',
];

// ─────────────────────────────────────────────────────────────
// Sections
// ─────────────────────────────────────────────────────────────

export const flagsSchema = z
  .object({
    'chat.enabled': flag(true, null as unknown as string),
    'chat.send': flag(),
    'chat.media': flag(),
    'chat.voice': flag(),
    'chat.location': flag(),
    'calls.audio': flag(),
    'calls.video': flag(),
    'visits.request': flag(),
    'visits.invite': flag(),
    'reviews.post': flag(),
    'listings.publish': flag(),
    'listings.edit': flag(),
    'boost.enabled': flag(),
    'favorites': flag(),
    'signup.enabled': flag(),
    'signup.method.otp': flag(),
    'signup.method.password': flag(),
    'signup.method.apple': flag(),
    'signup.method.google': flag(),
    'password.reset': flag(),
    'owners.signup': flag(),
    /// The KYC gate the product owner asked for: when true a user must have
    /// `identityVerified` before becoming an owner or publishing.
    'owners.identityRequired': flag(true),
    'identity.verification': flag(),
    'reports.file': flag(),
    /// The in-app support conversation. Off = the Help Center falls back to
    /// showing the support e-mail instead of opening a chat.
    'support.chat': flag(),
    /// The support assistant. Off = conversations simply wait for a human.
    /// It also stays off unless OPENROUTER_API_KEY is set, so switching this
    /// on without a key changes nothing.
    'support.ai': flag(false),
    'notifications.push': flag(),
    'maps': flag(),
    'share': flag(),
    'search.savedSearches': flag(),
    'home.carousel': flag(),
    'ads.banner': flag(false),
    'analytics': flag(),
    'account.delete': flag(),
  })
  .default({});

export const limitsSchema = z
  .object({
    /** Requests allowed per 15-minute window, per IP (per admin for adminWrite). */
    rateLimits: z
      .object({
        global: maxPerWindow(300),
        auth: maxPerWindow(20),
        otpRequest: maxPerWindow(5),
        smsSend: maxPerWindow(10),
        otpVerify: maxPerWindow(10),
        write: maxPerWindow(60),
        adminWrite: maxPerWindow(120),
      })
      .default({}),
    maxPhotosPerListing: z.number().int().min(1).max(60).default(30),
    maxListingsPerOwner: z.number().int().min(1).max(1000).default(50),
    priceMinFcfa: z.number().int().min(0).default(0),
    priceMaxFcfa: z.number().int().min(1).default(500_000_000),
    titleMaxLength: z.number().int().min(10).max(300).default(120),
    aboutMaxLength: z.number().int().min(50).max(20_000).default(5_000),
    messageMaxLength: z.number().int().min(50).max(20_000).default(4_000),
    reviewMinChars: z.number().int().min(0).max(500).default(0),
    reviewMaxChars: z.number().int().min(50).max(5_000).default(2_000),
    visitNoteMaxLength: z.number().int().min(50).max(2_000).default(500),
    visitsPerDayPerUser: z.number().int().min(1).max(200).default(20),
    visitMinHoursAhead: z.number().int().min(0).max(720).default(0),
    threadsPerDayPerUser: z.number().int().min(1).max(500).default(50),
    reportsPerDay: z.number().int().min(1).max(200).default(10),
    favoritesMax: z.number().int().min(1).max(10_000).default(1_000),
    searchResultsMax: z.number().int().min(10).max(500).default(100),
    listingCacheTtlSec: z.number().int().min(0).max(3_600).default(60),
  })
  .default({});

export const supportSchema = z
  .object({
    /// OpenRouter model slug. Defaults to a `:free` model, so the assistant
    /// costs nothing to run — at the price of tight rate limits. Free slugs
    /// come and go; check OpenRouter's model list and set whichever you want,
    /// no deploy needed. A paid slug (e.g. `anthropic/claude-sonnet-4.5`)
    /// works the same way.
    aiModel: z.string().max(80).default('google/gemma-4-31b-it:free'),
  })
  .default({});

export const boostSchema = z
  .object({
    plans: z
      .array(
        z.object({
          id: z.string().min(1).max(40),
          days: z.number().int().min(1).max(365),
          priceFcfa: z.number().int().min(0),
          label: z.string().min(1).max(60),
          popular: z.boolean().default(false),
        })
      )
      .max(10)
      .default([
        { id: 'boost3', days: 3, priceFcfa: 500, label: '3 jours', popular: false },
        { id: 'boost7', days: 7, priceFcfa: 1_000, label: '7 jours', popular: true },
        { id: 'boost30', days: 30, priceFcfa: 3_000, label: '30 jours', popular: false },
      ]),
  })
  .default({});

export const copySchema = z
  .object({
    maintenanceDefaultMessage: z
      .string()
      .max(300)
      .default('Nous améliorons Mobly. L’application sera de retour très vite.'),
    suspendedMessage: z
      .string()
      .max(300)
      .default('Votre compte a été suspendu. Contactez le support pour en savoir plus.'),
    featureDisabledMessage: z
      .string()
      .max(300)
      .default('Cette fonctionnalité est temporairement indisponible.'),
    signupClosedMessage: z
      .string()
      .max(300)
      .default('Les inscriptions sont temporairement fermées.'),
    homeBanner: z
      .object({
        enabled: z.boolean().default(false),
        title: z.string().max(80).default(''),
        body: z.string().max(200).default(''),
        ctaLabel: z.string().max(40).default(''),
        ctaUrl: z.string().max(500).default(''),
      })
      .default({}),
    announcementBar: z
      .object({
        enabled: z.boolean().default(false),
        text: z.string().max(200).default(''),
        /// info | warning | danger — drives the colour in the app.
        level: z.enum(['info', 'warning', 'danger']).default('info'),
        url: z.string().max(500).default(''),
      })
      .default({}),
    /// Extra business context for the support assistant — tone, current
    /// promotions, anything it should know. Appended to the safety rules,
    /// which are compiled in and cannot be edited from here.
    supportAiContext: z.string().max(4000).default(''),
    supportEmail: z.string().max(120).default('support@mobly.cm'),
    supportWhatsapp: z.string().max(40).default(''),
  })
  .default({});

export const contentSchema = z
  .object({
    categories: z.array(z.string().min(1).max(60)).max(50).default(CATEGORIES_DEFAULT),
    regions: z
      .array(
        z.object({
          name: z.string().min(1).max(60),
          cities: z.array(z.string().min(1).max(60)).max(100),
        })
      )
      .max(50)
      .default(REGIONS_DEFAULT),
    quartiers: z.record(z.array(z.string().min(1).max(80)).max(100)).default(QUARTIERS_DEFAULT),
    legal: z
      .object({
        cguVersion: z.string().max(20).default('1.0'),
        cguUrl: z.string().max(500).default(''),
        privacyVersion: z.string().max(20).default('1.0'),
        privacyUrl: z.string().max(500).default(''),
      })
      .default({}),
  })
  .default({});

export const versionsSchema = z
  .object({
    ios: z
      .object({
        /// Builds below this are refused with 426 FORCE_UPDATE. "0.0.0" = off.
        min: z.string().max(20).default('0.0.0'),
        latest: z.string().max(20).default('1.0.0'),
        storeUrl: z.string().max(500).default('https://apps.apple.com/app/mobly/id0000000000'),
        forceMessage: z
          .string()
          .max(300)
          .default('Une nouvelle version de Mobly est nécessaire pour continuer.'),
      })
      .default({}),
  })
  .default({});

export const geoSchema = z
  .object({
    /// Empty = every city allowed. Non-empty restricts publishing to this list.
    allowedCities: z.array(z.string().min(1).max(60)).max(200).default([]),
    defaultCity: z.string().max(60).default('Douala'),
    allowedCountryCodes: z.array(z.string().min(2).max(6)).max(20).default(['+237']),
  })
  .default({});

/** Admin-only. Never reaches the app — see `toPublicConfig`. */
export const securitySchema = z
  .object({
    /// Empty = allow every IP. Non-empty restricts the whole /admin surface.
    adminIpAllowlist: z.array(z.string().min(3).max(64)).max(100).default([]),
    otp: z
      .object({
        length: z.number().int().min(4).max(8).default(4),
        ttlSec: z.number().int().min(60).max(3_600).default(300),
        maxAttempts: z.number().int().min(1).max(10).default(3),
        resendCooldownSec: z.number().int().min(0).max(600).default(60),
      })
      .default({}),
    password: z
      .object({
        minLength: z.number().int().min(6).max(64).default(8),
        requireDigit: z.boolean().default(false),
      })
      .default({}),
    lockout: z
      .object({
        /// 0 disables lockout entirely.
        maxFails: z.number().int().min(0).max(50).default(10),
        lockMinutes: z.number().int().min(1).max(1_440).default(15),
      })
      .default({}),
    /// Grace period before an account marked for deletion is anonymised.
    accountDeletionGraceDays: z.number().int().min(0).max(365).default(30),
    /// Destructive admin actions require the operator to type a phrase.
    requireConfirmPhrase: z.boolean().default(true),
  })
  .default({});

/** Admin-only: publishing the blocklist would tell spammers exactly what to avoid. */
export const moderationSchema = z
  .object({
    blockedWords: z.array(z.string().min(2).max(60)).max(500).default([]),
    /// 0 disables. Otherwise a listing is auto-paused after N open reports.
    autoPauseListingAfterReports: z.number().int().min(0).max(100).default(0),
  })
  .default({});

export const notificationsSchema = z
  .object({
    quietHours: z
      .object({
        enabled: z.boolean().default(false),
        startHour: z.number().int().min(0).max(23).default(22),
        endHour: z.number().int().min(0).max(23).default(7),
      })
      .default({}),
    dailyPushCapPerUser: z.number().int().min(1).max(100).default(10),
  })
  .default({});

// ─────────────────────────────────────────────────────────────
// Document
// ─────────────────────────────────────────────────────────────

export const appConfigSchema = z
  .object({
    flags: flagsSchema,
    limits: limitsSchema,
    boost: boostSchema,
    support: supportSchema,
    copy: copySchema,
    content: contentSchema,
    versions: versionsSchema,
    geo: geoSchema,
    security: securitySchema,
    moderation: moderationSchema,
    notifications: notificationsSchema,
  })
  .default({});

/** Fixed window for every rate limiter — see `maxPerWindow`. */
export const RATE_LIMIT_WINDOW_MS = 15 * 60 * 1000;

export type AppConfigDoc = z.infer<typeof appConfigSchema>;
export type FlagKey = keyof AppConfigDoc['flags'];

/** Every section name, for `POST /admin/config/reset-section`. */
export const CONFIG_SECTIONS = [
  'flags', 'limits', 'boost', 'copy', 'content',
  'versions', 'geo', 'security', 'moderation', 'notifications', 'support',
] as const;
export type ConfigSection = (typeof CONFIG_SECTIONS)[number];

/** Sections only a SUPER_ADMIN may write. */
export const RESTRICTED_SECTIONS: ConfigSection[] = ['security'];

/** Parsing `{}` gives the app exactly as it ships — see the rule above. */
export const DEFAULT_CONFIG: AppConfigDoc = appConfigSchema.parse({});

export const FLAG_KEYS = Object.keys(DEFAULT_CONFIG.flags) as FlagKey[];

/**
 * What the app is allowed to see. `security` would hand an attacker the OTP
 * and lockout policy, and `moderation.blockedWords` is a spam-filter bypass
 * list — both stay server-side.
 */
export function toPublicConfig(doc: AppConfigDoc) {
  return {
    flags: doc.flags,
    limits: {
      maxPhotosPerListing: doc.limits.maxPhotosPerListing,
      maxListingsPerOwner: doc.limits.maxListingsPerOwner,
      priceMinFcfa: doc.limits.priceMinFcfa,
      priceMaxFcfa: doc.limits.priceMaxFcfa,
      titleMaxLength: doc.limits.titleMaxLength,
      aboutMaxLength: doc.limits.aboutMaxLength,
      messageMaxLength: doc.limits.messageMaxLength,
      reviewMinChars: doc.limits.reviewMinChars,
      reviewMaxChars: doc.limits.reviewMaxChars,
      visitNoteMaxLength: doc.limits.visitNoteMaxLength,
      visitMinHoursAhead: doc.limits.visitMinHoursAhead,
      favoritesMax: doc.limits.favoritesMax,
      searchResultsMax: doc.limits.searchResultsMax,
    },
    boost: doc.boost,
    copy: doc.copy,
    content: doc.content,
    versions: doc.versions,
    geo: doc.geo,
  };
}

export type PublicConfig = ReturnType<typeof toPublicConfig>;
