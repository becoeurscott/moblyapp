# Identity verification (Didit) — setup

Self-serve "badge vérifié" for Mobly. Replaces the admin-only toggle: a user
starts a check from Profil → Vérification d'identité, and `User.identityVerified`
is flipped by Didit's webhook.

Provider: **Didit** (https://didit.me) — docs at https://docs.didit.me.
Free tier is 500 verifications/month; the full KYC bundle is ~$0.33 each.

> The old `DIDI_INTEGRATION_SETUP.md` in the prototype repo named a
> "DiDi API" at `developer.didi.com`. No such identity product exists — DiDi is
> the ride-hailing company. This is the real one.

## How it works

```
app  ──POST /verification/session──▶  backend  ──POST /v3/session/──▶  Didit
app  ◀───── { url } ────────────────  backend  ◀──── { session_id, url }
app  ── opens url in SFSafariViewController ──▶  Didit hosted flow
                                                 (ID photo + selfie)
backend  ◀── POST /verification/webhook (signed) ──  Didit
   └─ status APPROVED → User.identityVerified = true
app  ── GET /verification/me ──▶ badge refreshes
```

The document photos and the selfie go **straight to Didit**. Mobly never
receives, stores, or proxies an ID scan — which is the reason to use the hosted
flow rather than uploading base64 images ourselves.

## 1. Create the account and workflow

1. Sign up at https://business.didit.me and create an application → copy the API key.
2. Create a KYC workflow (console → Workflows) with OCR + passive liveness +
   face match. Copy its id.

Or by API:

```bash
curl -X POST https://verification.didit.me/v3/workflows/ \
  -H "x-api-key: $DIDIT_API_KEY" -H "Content-Type: application/json" \
  -d '{"workflow_label":"Mobly KYC","workflow_type":"kyc","features":[
       {"feature":"OCR"},
       {"feature":"LIVENESS","config":{"face_liveness_method":"PASSIVE"}},
       {"feature":"FACE_MATCH"}]}'
```

## 2. Register the webhook

Console → **API & Webhooks** → new destination:

- URL: `https://<your-host>/api/v1/verification/webhook`
- Version: `v3`
- Events: `status.updated`

**Copy `secret_shared_key` immediately — it is shown once.** That value is
`DIDIT_WEBHOOK_SECRET`. Without it the endpoint rejects every webhook, by
design: an unsigned "Approved" would be a free verified badge for anyone who
finds the URL.

## 3. Environment

```bash
DIDIT_API_KEY=              # server-only, never in the app binary
DIDIT_WORKFLOW_ID=
DIDIT_WEBHOOK_SECRET=       # secret_shared_key from step 2
DIDIT_BASE_URL=https://verification.didit.me
DIDIT_CALLBACK_URL=moblyapp://kyc/return
```

On Render these are already declared in `render.yaml` with `sync: false` —
fill them in the dashboard.

## 4. Migrate

```bash
npx prisma migrate deploy
```

Adds `IdentityCheck` (one row per provider session, holding its status and
hosted URL) plus the `IdentityStatus` enum. `User.identityVerified` already
existed — it was previously only settable by an admin.

## API

| Route | Auth | Purpose |
|---|---|---|
| `POST /verification/session` | Bearer | Start a check → `{ checkId, url, status }`. Returns 409 if already verified. Rate-limited to 5/hour per user, and an in-flight session (under 30 min old, confirmed still open with the provider) is handed back rather than re-created — each new session is billable. |
| `GET /verification/me` | Bearer | `{ identityVerified, status, reason, verifiedAt }`. Polls the provider when the local row is still open, so a dropped webhook can't strand a user on "pending". |
| `POST /verification/webhook` | HMAC signature | Didit's callback. Unauthenticated by design — the signature is the auth. |

Statuses: `NONE · PENDING · IN_REVIEW · APPROVED · DECLINED · ABANDONED`.

## Security notes

- **Signature is mandatory.** `verifyWebhook` fails closed on a missing secret,
  a missing/garbage signature, or a timestamp more than 300s off (replay
  window). Verified with `X-Signature-V2` — canonical sorted-key JSON — because
  Express has already re-serialised the body by then; the raw-body
  `X-Signature` would not survive that.
- **Unknown statuses map to PENDING, never APPROVED.** A status Didit adds
  later must not accidentally grant a badge.
- **The badge is only ever set forward.** A late webhook for an old session
  cannot strip a badge the user already earned.
- **`vendor_data` carries our user id**, so a decision is attributed from the
  provider's payload rather than anything the client sends.
- The API key stays server-side; the app only ever sees a one-shot hosted URL.

## iOS

- `Services/IdentityVerificationStore.swift` — state machine + polling.
- `Screens/Profile/IdentityVerificationView.swift` — the screen; opens the
  hosted URL in `SFSafariViewController` (a real browser, so the user can see
  who they are handing their ID to, and camera permission works).
- The Profil identity row now reads `identityVerified` (the KYC result) rather
  than `verified` (which only means the phone was confirmed) and links here.

### About the callback URL

The app does **not** currently register a `moblyapp://` URL scheme (the target
uses a generated Info.plist, and `CFBundleURLTypes` needs a real one). That is
fine: the user taps **Done** to close the Safari sheet, and `onDisappear`
triggers the status poll, so the badge refreshes either way.

Registering the scheme is an optional polish step — it would let Didit's
callback dismiss the sheet automatically. It requires adding an `Info.plist`
with `CFBundleURLTypes` to the target; keep `DIDIT_CALLBACK_URL` in sync if you
do. Until then, any valid URL works there.
