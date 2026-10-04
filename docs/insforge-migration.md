# Move Mobly Fully To InsForge

Goal: run the Mobly backend, database, storage direction, logs and future realtime
from the linked InsForge project instead of Render plus Supabase.

Current linked project:

- Project: `mobly`
- Region: `eu-central`
- API base: `https://fe6jdhqj.eu-central.insforge.app`
- Instance: `nano`

## Recommended Order

1. Keep the iOS API contract unchanged.
2. Restore/import the current production database into InsForge Postgres.
3. Apply Prisma migrations against InsForge.
4. Deploy this Node API as InsForge compute.
5. Point the iOS app API base URL to the InsForge compute endpoint.
6. Move storage/auth modules later, after the API is stable.

Do not rewrite auth first. The app already depends on custom JWT sessions, OTP,
OAuth, admin restrictions, owner trials, chat, visits and support flows. Moving
the database and API runtime first gives the speed benefit with much less risk.

## Container

The repo now has a `Dockerfile` for the existing Express/Prisma backend. The app
listens on port `4000`, so deploy compute with `--port 4000`.

Example:

```bash
npx -y @insforge/cli compute deploy . \
  --name mobly-api \
  --port 4000 \
  --region fra \
  --cpu shared-1x \
  --memory 512 \
  --env-file ./.env.insforge.production
```

Use `shared-1x` first for budget. Upgrade only if slow-request logs show CPU or
memory pressure.

## Required Environment

Create `.env.insforge.production` locally and keep it uncommitted.

Required:

```bash
NODE_ENV=production
PORT=4000
API_PREFIX=/api/v1
TRUST_PROXY=1
CORS_ORIGINS=*
DATABASE_URL=...
DIRECT_URL=...
JWT_ACCESS_SECRET=...
JWT_REFRESH_SECRET=...
JWT_ACCESS_TTL=15m
JWT_REFRESH_TTL=30d
OTP_DEV_MODE=false
```

Also copy the real production values you still use:

```bash
TWILIO_ACCOUNT_SID=...
TWILIO_AUTH_TOKEN=...
TWILIO_VERIFY_SERVICE_SID=...
TWILIO_MESSAGING_SERVICE_SID=...
CLOUDINARY_CLOUD_NAME=...
CLOUDINARY_API_KEY=...
CLOUDINARY_API_SECRET=...
CLOUDINARY_UPLOAD_FOLDER=mobly/listings
GOOGLE_CLIENT_IDS=...
APPLE_BUNDLE_IDS=cm.mobly.app
APNS_KEY_ID=...
APNS_TEAM_ID=...
APNS_BUNDLE_ID=cm.mobly.app
APNS_PRODUCTION=true
APNS_KEY=...
DIDIT_API_KEY=...
DIDIT_WEBHOOK_SECRET=...
PAYMENTS_PROVIDER=stub
PAYMENTS_WEBHOOK_SECRET=...
```

## Database

The Prisma schema currently defines Mobly's full application database. Use
InsForge Postgres as the source of truth, but keep Prisma for this Node API.

After setting `DATABASE_URL` and `DIRECT_URL` to InsForge Postgres:

```bash
npm run prisma:deploy
```

For a production migration from Supabase, export/import data first, then run
pending migrations. Test against a copy before switching live traffic.

## iOS Switch

After compute deploy returns its endpoint, update the app's API base URL to that
endpoint. Keep the path prefix `/api/v1`.

Test these flows before App Store/TestFlight release:

- Launch with existing token
- Sign in
- Home listings
- Listing detail
- Message owner
- Existing conversation
- Visit request
- Owner dashboard
- Push registration
- Image upload

## Later Moves

After the API is stable on InsForge:

- Move images from Cloudinary to InsForge Storage if cost or simplicity matters.
- Consider InsForge Auth only for a future major auth rewrite.
- Use InsForge realtime only after the current WebSocket chat is stable.
