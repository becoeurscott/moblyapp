# Mobly Backend

REST API for the Mobly marketplace app. **Node.js + Express + TypeScript + Prisma + PostgreSQL (Supabase).**

Base path is configurable via `API_PREFIX` (currently **`/api/v1`**). `/api` stays mounted as a legacy alias.

## What it manages
Auth (phone OTP + JWT), users/roles (visitor ↔ owner), listings (CRUD + search/filter), owner dashboard (metrics, availability), **boost** (plans + activation), favorites, chat threads/messages, notifications, reviews, and geo/category reference data.

## Run locally

1. **Install deps**
   ```bash
   cd backend
   npm install
   ```
2. **Database (Supabase)** — copy the env template and fill it in:
   ```bash
   cp .env.example .env
   ```
   Two connection strings are required:
   - `DATABASE_URL` → **pooler** (`…pooler.supabase.com:6543`, `?pgbouncer=true&connection_limit=1`), used at runtime.
   - `DIRECT_URL` → **direct** (`db.<ref>.supabase.co:5432`), used by Prisma for migrations — pgbouncer cannot run them.

   Percent-encode special characters in the password (`@` → `%40`, `#` → `%23`, `!` is safe).
3. **Migrate + seed**
   ```bash
   npm run prisma:migrate      # creates tables
   npm run prisma:seed         # demo owner + listings
   ```
4. **Start**
   ```bash
   npm run dev                 # http://localhost:4000
   ```
   Check: `GET http://localhost:4000/api/v1/health`

## Deploy (Render, free tier)
1. Push this `backend/` folder to a GitHub repo.
2. Render → **New → Blueprint** → select the repo. `render.yaml` deploys the web service only — the database is Supabase.
3. In the Render dashboard, paste the values marked `sync: false`: `DATABASE_URL`, `DIRECT_URL`, and the Cloudinary keys.
4. After first deploy, run the seed once from the Render shell: `npm run prisma:seed`.
5. Your base URL is `https://<your-service>.onrender.com` — point the iOS app's `MoblyAPI.baseURL` at `.../api/v1`.

Railway is similar: set the same env vars, build `npm install && npm run build && npx prisma migrate deploy`, start `npm start`.

## Auth flow (OTP)
- `POST /api/auth/otp/request { phone }` → sends a code. In dev (`OTP_DEV_MODE=true`) the code is returned as `devCode` and logged so the app can auto-fill it. **Wire a real SMS provider in `src/services/otp.ts` before production.**
- `POST /api/auth/otp/verify { phone, code, fullName?, isOwner? }` → returns `{ token, user }`. Send `Authorization: Bearer <token>` on protected routes.

## Endpoint map
| Method | Path | Auth | Purpose |
|---|---|---|---|
| GET | `/api/v1/health` | – | health check |
| POST | `/api/v1/auth/otp/request` | – | request OTP |
| POST | `/api/v1/auth/otp/verify` | – | verify OTP → token |
| GET/PATCH | `/api/v1/auth/me` | ✓ | current user / update / become owner |
| GET | `/api/v1/listings` | – | search + filter (query, category, city, deal, price…) |
| GET | `/api/v1/listings/:id` | – | one listing (bumps views) |
| POST | `/api/v1/listings` | owner | publish (→ PENDING) |
| PATCH | `/api/v1/listings/:id` | owner | edit |
| PATCH | `/api/v1/listings/:id/availability` | owner | toggle disponible |
| DELETE | `/api/v1/listings/:id` | owner | delete |
| GET | `/api/v1/owner/annonces` | owner | my listings + metrics |
| GET | `/api/v1/owner/overview` | owner | 30-day aggregate |
| GET | `/api/v1/owner/stats/:id` | owner | per-listing stats |
| GET | `/api/v1/boost/plans` | – | boost plans + per-day/savings |
| POST | `/api/v1/boost/:listingId` | owner | activate boost |
| GET/POST/DELETE | `/api/v1/favorites[/:listingId]` | ✓ | favorites |
| GET/POST | `/api/v1/threads` | ✓ | chat threads |
| GET/POST | `/api/v1/threads/:id/messages` | ✓ | messages |
| GET | `/api/v1/notifications` | ✓ | notifications |
| GET/POST | `/api/v1/listings/:id/reviews` | mixed | reviews |
| GET | `/api/v1/geo` · `/api/v1/categories` | – | pickers reference data |

## Environment
| Group | Vars |
|---|---|
| Runtime | `NODE_ENV` `PORT` `API_PREFIX` `CORS_ORIGINS` `TRUST_PROXY` |
| Database | `DATABASE_URL` (pooler) `DIRECT_URL` (migrations) |
| Auth | `JWT_ACCESS_SECRET` `JWT_REFRESH_SECRET` `JWT_ACCESS_TTL` `JWT_REFRESH_TTL` `OTP_DEV_MODE` |
| Images | `CLOUDINARY_CLOUD_NAME` `CLOUDINARY_API_KEY` `CLOUDINARY_API_SECRET` `CLOUDINARY_UPLOAD_FOLDER` |
| Share | `WHATSAPP_MESSAGE_TEMPLATE` (share-a-listing only — contact stays in-app) |
| Payments | `PAYMENTS_PROVIDER` (`stub` auto-settles) `PAYMENTS_WEBHOOK_SECRET` |

Legacy `JWT_SECRET` / `JWT_EXPIRES_IN` are still honoured as fallbacks.

## Notes on money
`POST /api/boost/:listingId` only records the boost and elevates the listing — it does **not** charge money. In production, confirm the Mobile Money payment via your provider's webhook first, then call this. Same principle applies to escrow/caution.
