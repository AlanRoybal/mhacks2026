# Bounty Twin API

The contract between the iOS app and the backend (`backend/`). One server answers three kinds of client:

| Client | Where it lives | What it calls |
|---|---|---|
| **TwinKit** (iosA's networking package) | `Packages/TwinKit` on `main` | snake_case routes: `/auth/linkedin-callback`, `/profile/*`, `/offers/{id}/respond` ([TwinKit routes](#twinkit-routes)) |
| **Payments checkout** | `Bounty/Features/Post/PaymentCheckoutView.swift` (payments branch) | `POST /payment-sheet`, `GET /jobs/{uuid}` ([Checkout routes](#checkout-routes)) |
| **Everything else** (jobs, proof, review, wallet) | Not wired in the app yet | camelCase routes, documented below. The Job JSON matches iOS-B's `Job.swift` as of commit 849925c. iOS-B has since cut `JobCategory` to five values, so it can't decode `HOME`, `MOVING`, `PHOTOGRAPHY`, `TECHNOLOGY` or `OTHER`. |

For how the backend works inside, see [BACKEND.md](BACKEND.md). For how to run it, see [backend/README.md](../backend/README.md).

## Conventions

| Topic | Rule |
|---|---|
| Base URL | Local: `http://<laptop-ip>:8787` (`npm run dev`). The app reads it from `BountyAPIBaseURL`, set by `BOUNTY_API_BASE_URL` in `Config/Local.xcconfig`. For a phone, also set `PUBLIC_BASE_URL=http://<laptop-ip>:8787` in `backend/.env`, because upload and file links are built from it. |
| Auth | `Authorization: Bearer <token>` everywhere except `/health`, `/auth/*`, `/files/*`, `/local-blobs/*`, `/webhooks/*`, `/wallet/connect/return\|refresh`, and the checkout routes. Tokens last 30 days. |
| Bodies | JSON. Send `Content-Type: application/json`. |
| Money | Dollars as JSON numbers (`15`, `16.5`), except TwinKit and the checkout, which use their own integer-cents fields. The poster pays the bounty plus a 10% fee. Bounties run from $5 to $1000. |
| Distance | Miles. |
| Location | `{ "latitude", "longitude", "address" }`. A job `location` of `null`, or missing, means remote. |
| Dates | ISO-8601 without fractional seconds (`2026-10-04T21:00:00Z`); use `.iso8601`. The one exception is checkout `FundedJob.deadline`, which has milliseconds because that client parses them. |
| Enums | Uppercase: `JobStatus`, `JobCategory` (`DESIGN`, `HOME`, `YARD_WORK`, `MOVING`, `TUTORING`, `PHOTOGRAPHY`, `TECHNOLOGY`, `ERRANDS`, `OTHER`), `EvidenceType` (`PHOTO`, `CHECK_IN`, `LINK`, `FILE`), `PayCurrency`. |
| Errors | `{ "error": { "code": "<code>", "message": "<text for the user>" } }`. This is TwinKit's `APIErrorEnvelope`: switch on `code`, show `message`. The checkout routes are the only exception; they return `{ "error": "<message>" }`. |
| Updates | Mutations return the updated Job unless noted. Poll `GET /jobs/{id}` every 2 s on screens that wait for the server; push covers the rest. |

### Error codes

| HTTP | `code` | Meaning |
|---|---|---|
| 400 | `invalid_request`, `bad_request`, `invalid_amount`, `unknown_upload`, `unsupported_type`, `upload_missing`, `too_large`, `location_required`, `not_configured` | Fix the request; `message` says what's wrong. `invalid_amount` means pay outside $5–$1000. `not_configured` covers LinkedIn sign-in. |
| 400 | `bad_signature` | Only from `/webhooks/stripe`. |
| 401 | `unauthorized` | Missing or expired token, or a failed LinkedIn or Apple exchange. TwinKit turns every 401 into `APIError.unauthorized` and drops `message`, so a bad LinkedIn code shows as an expired session. |
| 403 | `forbidden` | You can see the job but can't take this action. Admin-only routes, and demo routes without the demo key, also return this. Someone else's offer, or a job you can't see, is a 404. |
| 404 | `not_found` | Unknown, or not visible to you. |
| 409 | `invalid_transition` | Not allowed in the job's current status. Refresh the job and check `allowedActions`. |
| 409 | `offer_not_current` | Someone else got the job, or the offer moved on (US-26 "already taken"). |
| 409 | `offer_expired` | The server's expiry passed, even if the device countdown didn't. |
| 409 | `not_enough_time`, `deadline_passed`, `window_closed`, `already_done`, `already_submitted`, `locked`, `checkout_started`, `already_funded`, `checklist_incomplete`, `nothing_to_do`, `busy` | See `message`. `busy` means retry. `checklist_incomplete`: add a required photo, link or file item before funding. |
| 422 | `too_far` | Check-in more than 200 m from the job (500 m in demo mode). |
| 422 | `too_large` | The local upload PUT was over the size limit. |
| 422 | `proof_incomplete` | Proof failed the server checks. The body also has `checks` (see [Proof](#proof)). |
| 500 | `internal` | A server bug. The details are in the server log. |
| 501 | `rail_unavailable`, `not_configured` | USDC funding, or Stripe Connect on a server without Stripe keys. |

## Sign-in (US-01)

Every sign-in returns the same session body:

```json
{ "token": "...", "userId": "...", "access_token": "...", "refresh_token": null, "expires_in": 2592000, "user_id": "..." }
```

`access_token`, `expires_in` and `user_id` are what TwinKit's `AuthSessionResponse` decodes. There is no refresh token; sign in again after 30 days.

| Method | Path | Body | Notes |
|---|---|---|---|
| POST | `/auth/linkedin-callback` | `{ "code", "code_verifier", "redirect_uri" }` | TwinKit's `LinkedInAuthenticator`: PKCE runs on the device and the server exchanges the code with the client secret. `redirect_uri` must be the one the app used (`bounty://oauth/linkedin`) and must be registered in the LinkedIn app. LinkedIn may refuse custom-scheme redirect URLs; if it does, use the next row. |
| GET | `/auth/linkedin/start` | — | Server-side alternative: open it in `ASWebAuthenticationSession` with callback scheme `bounty`. It ends at `bounty://auth?token=...` or `bounty://auth?error=linkedin_failed`. It returns only the token, so the app builds its own session and reads `userId` from `GET /me`. Needs `<api>/auth/linkedin/callback` registered with LinkedIn. |
| POST | `/auth/apple` | `{ "identityToken", "fullName" }` | Apple sends the name only on the first sign-in, so pass it then. |
| POST | `/auth/demo` | `{ "handle": "judge", "displayName": "Judge" }` | Handles are lowercase letters, digits, `-` or `_`. The same handle is always the same account. Handle `admin` is an admin in local dev only; deployed admins come from `ADMIN_USER_IDS`. Allowed in local dev; on a deployed stage it needs `DEMO_MODE`, `DEMO_LOGIN_KEY`, and the header `x-demo-key: <key>`. |
| GET | `/me` | — | `{ userId, displayName, email, photoUrl, isAdmin, payouts: { stripeConnected, stripeTransfersEnabled }, pushEnabled, stats: { …counts, acceptRate, completionRate, reliability, workerRating, posterRating }, createdAt }` (US-58). |
| PATCH | `/me` | `{ "displayName" }` | |
| DELETE | `/me` | — | 204. Deletes the account: clears the name, email, photo, twin, preferences, availability and devices, and unlinks the sign-in identities so the next sign-in starts fresh. Jobs and ledger rows stay. 409 `open_jobs` while any job is FUNDED through DISPUTED. |
| POST | `/me/devices` | `{ "token": "<hex APNs token>", "env": "sandbox" \| "production" }` | Call it on every launch. `sandbox` is for Xcode builds and `production` for TestFlight. The server deletes tokens Apple rejects, which puts `notifications` back into `readiness.missing` and stops the worker being matched. |

## TwinKit routes

These are the paths and DTOs `Packages/TwinKit` hard-codes. They sit on the same services as the camelCase routes, so behavior is identical.

| Method | Path | Body | Returns |
|---|---|---|---|
| GET | `/profile/twin` | — | `TwinProfile`: `{ user_id, headline, skills: [{ id, name, confidence, source, years_of_experience }], roles: [String], education: [String], certifications, updated_at }`. `source` is `linkedin`, `resume`, `email` or `user`. |
| PUT | `/profile/twin/skills` | `{ "skills": [TwinSkill] }` | The full edited list becomes the twin's skills. A skill left out is deleted and stays deleted on later imports. Returns `TwinProfile`. |
| POST | `/profile/upload-url` | `{ file_name, content_type: "application/pdf" \| "application/zip" \| "application/x-zip-compressed", byte_count, source: "resume" \| "linkedin_pdf" \| "linkedin_export" }` | `{ upload_url, object_key, headers }`. PUT the file to `upload_url` with `headers`. Other types (TwinKit also allows .doc and .docx) get 400 `unsupported_type`, and over 20 MB gets 400 `too_large`. `resume` and `linkedin_pdf` need a PDF, and `linkedin_export` the ZIP. A mismatch is accepted here and fails during the import. |
| POST | `/profile/ingest` | `{ object_key, source }` | 202 `{ ingestion_id, status: "processing" }`, or 400 `unknown_upload`, `upload_missing` or `too_large`. Import runs in the background; poll `GET /twin` for `ingest.status` (`done` / `failed` + `error`) or re-read `/profile/twin`. |
| PUT | `/profile/availability` | `{ generated_at, window_start, window_end, busy_blocks: [{ start, end }] }` | 204. Busy blocks replace the previous ones; the worker's weekly hours and time zone are kept. |
| POST | `/offers/{id}/respond` | `{ "decision": "accept" \| "decline" }` | `{ offer_id, job_id, status }`, where `status` is the job's status (for example `ACCEPTED`). Exactly one worker wins. Anyone else gets `offer_not_current`, or 404 if the offer isn't theirs. |

TwinKit's `JobOffer` DTO has no endpoint yet. Use `GET /offers/{id}`, described below, from the push.

## Checkout routes

These are for `PaymentCheckoutView` from the payments branch. They replace its sandbox server: the paid job becomes a real job that gets matched. Point `BOUNTY_PAYMENTS_BASE_URL` at this backend to use them. The old server still runs from `payments-server/` if you need it.

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/payment-sheet` | `FundingDraft { id (UUID), title, details, category: Design\|Home\|Tutoring\|Photography\|Technology, isRemote, deadline, amountCents }`, plus an optional `location { latitude, longitude, address }` | `{ job: FundedJob, paymentIntentClientSecret, publishableKey }`. `FundedJob` is `{ id, title, details, category, isRemote, deadline, amountCents, feeCents, totalCents, currency: "usd", status: "draft" \| "funded" \| "refunded" }`. A retry with the same `id` reuses the job. |
| GET | `/jobs/{uuid}` | — | `FundedJob`. If no webhook has arrived yet, it confirms payment by asking Stripe. If the request has an `Authorization` header, the normal Job view answers instead. |

- **Auth:** the checkout sends no session today. Local dev assigns those jobs to a shared guest poster. On a deployed stage, send `Authorization: Bearer <token>` on `POST /payment-sheet`, or it returns 401. Don't send it on `GET /jobs/{uuid}`: with that header the normal Job view answers, which `FundedJob` can't decode. Release builds also require HTTPS.
- **Location:** in-person jobs without `location` are placed at a campus default until the app sends one.
- **Errors** are `{ "error": "<message>" }`, which the checkout already shows.
- **Fake payments** (`PAYMENTS_PROVIDER=fake`, the default): the job comes back `funded`, so the app records it and skips the sheet. `pk_test_fake` only exists to pass the app's `pk_test_` check.
- **A job that isn't a draft any more** comes back with `paymentIntentClientSecret: ""`. The app handles `funded`. For `refunded`, it shows a Pay button that fails on tap, so start a new checkout with a new `id`.

## Uploads

Every file uses two steps: presign, then PUT.

1. `POST /uploads/presign` with `{ "contentType": "image/jpeg" }`. Allowed types are `image/jpeg`, `image/png`, `image/webp`, `image/heic`, `application/pdf` and `application/zip`.
2. `PUT` the bytes to `uploadURL` with exactly the returned `headers`.
   - Don't send your `Authorization` header on this PUT. S3 rejects a request that carries both a presigned signature and a token.
   - Presign once per file.

The response:

```json
{ "uploadURL": "...", "method": "PUT", "headers": { "content-type": "image/jpeg" }, "expiresAt": "2026-10-04T15:05:00Z",
  "fileURL": "https://<api>/files/uploads/<you>/<id>.jpg?sig=...", "blobKey": "uploads/<you>/<id>.jpg" }
```

`fileURL` never expires, so you can store it (in `posterPhotos`, for example) and load it with `AsyncImage`; it redirects to a short-lived download. Refer to uploads by `fileURL` or `blobKey`.

Size limits are 5 MB per photo and 20 MB per file. Send JPEG at about 1600 px on the longest side; the grader can't read HEIC.

## Twin (US-02 to US-08)

| Method | Path | Body | Notes |
|---|---|---|---|
| GET | `/twin` | — | `{ displayName, summary, yearsExperience, skills, roles, education, certifications, ingest: { status, error, sources, updatedAt }, prefs, availability, readiness }`. `availability` is null until set; skill `category` can be null. |
| POST | `/twin/ingest` | `{ "fileURL" \| "blobKey", "kind": "resume_pdf" \| "linkedin_pdf" \| "linkedin_zip" }` | 202 with `ingest.status: "processing"`; poll until it's `done` or `failed`. |
| POST | `/twin/skills` | `{ "name", "level": 1-5, "category" }` | Adds a skill, edits one, or restores a deleted one, matched by name. |
| DELETE | `/twin/skills/{normName}` | — | `normName` comes from `GET /twin`. Deleted skills stay deleted on later imports. |
| PUT | `/twin/prefs` | Any of `minPay`, `maxRadiusMiles`, `blockedCategories`, `remoteOk`, `inPersonOk`, `tz`, `quietHours { start, end }` or `null`, `base { latitude, longitude }` or `null` | Set `base` from the device location; distance is measured from it. |
| PUT | `/twin/availability` | `{ "tz", "weekly": "<168 chars of 0/1, Monday 00:00 first>", "busy": [{ start, end }] }` | `busy` is required; send `[]` without calendar access. |

A skill in `GET /twin` looks like this:

```json
{ "normName": "logo design", "name": "Logo design", "category": "design", "level": 4, "confidence": 0.94,
  "userEdited": false, "sources": [{ "kind": "linkedin", "label": "LinkedIn", "evidence": "Graphic Designer at Michigan Daily" }] }
```

`readiness` is `{ ready, missing, recommended }`.
- `missing` lists what blocks matching: `skills`, `notifications`, and `payouts` (only when Stripe is on).
- `recommended` lists what would help: `location` and `availability`.

## Jobs

### Poster

| Method | Path | Body | Notes |
|---|---|---|---|
| POST | `/jobs` (alias `/jobs/create`) | `title` (3–80), `description` (1–2000, required), `category`, `location` (or null/missing), `deadline` (30 minutes to 30 days away), `payAmount`, `currency`, `posterPhotos` (fileURLs), optional `radiusMiles` | 201 with a DRAFT Job and an AI-generated checklist. |
| GET | `/jobs/mine` | — | Jobs you posted, newest first. |
| GET | `/jobs/{id}` | — | Visible to the poster, the assigned worker, the worker currently being offered the job, and admins. Anyone else, including a worker whose offer ended, gets 404; send them to the offer outcome screen. |
| PATCH | `/jobs/{id}` | Any draft fields | DRAFT only, before checkout. Fields you leave out keep their values. |
| PUT | `/jobs/{id}/checklist` | `[ChecklistItem]` or `{ "checklist": [...] }` | DRAFT only. App-made ids are kept, and omitted fields keep their old values. In-person jobs always keep a `CHECK_IN` item. At least one photo, link or file item must stay required. |
| POST | `/jobs/{id}/checklist/regenerate` | — | Asks the AI again. |
| DELETE | `/jobs/{id}` | — | Drafts only. 204 with no body. |
| GET | `/jobs/{id}/quote` | — | `{ payAmount, feeAmount, totalAmount, currency }` (US-15). |
| POST | `/jobs/{id}/fund` | — | Returns a FundingSession (see [Payments](#payments)). |
| POST | `/jobs/{id}/cancel` | — | Before a worker accepts (US-18). Full refund. |
| PATCH | `/jobs/{id}/terms` | `{ "deadline", "radiusMiles" }` | Only when `allowedActions` contains `update_terms`, which means FUNDED with no offer out. Same deadline rule as posting. Restarts matching. |
| POST | `/jobs/{id}/approve` | — | IN_REVIEW, or DISPUTED to drop your dispute. Releases payment (US-46). |
| POST | `/jobs/{id}/reject` | — | Only after the AI failed the work and the worker's retries are used up. Refunds you. |
| POST | `/jobs/{id}/dispute` | `{ "checklistItemId", "note" }` | During the review window (US-50). |
| POST | `/jobs/{id}/rating` | `{ "stars": 1-5, "comment" }` | After RELEASED or REFUNDED (US-56/57). |
| GET | `/jobs/{id}/timeline` | — | `[{ seq, type, status, from, label, actor: you\|poster\|worker\|platform\|admin, at }]` (US-49). |

### Worker

| Method | Path | Body | Notes |
|---|---|---|---|
| GET | `/offers/current` | — | `{ offer, job }`, or `{ offer: null, job: null }`. It reads an eventually consistent index, so right after a push use the next row instead. |
| GET | `/offers/{id}` | — | `{ offer, job }`. Open this from the push, which carries `offerId`. `job` is filled while the offer is live or after you win it; otherwise null. |
| POST | `/offers/{id}/accept` | — | `{ offer, job }`. A second tap by the winner is a 200. |
| POST | `/offers/{id}/decline` | — | `{ offer, job: null }`. The job moves to the next match. |
| GET | `/jobs/working` | — | Jobs assigned to you, active and finished. |
| POST | `/jobs/{id}/start` | `{ "latitude", "longitude" }` in person, `{}` remote | Check-in. The response's `challengeCode` (like `K7R-4MX`) must be visible in proof photos. It's shown while IN_PROGRESS, SUBMITTED and IN_REVIEW. |
| POST | `/jobs/{id}/withdraw` | — | 204. Gives the job back before submitting; it re-opens for matching and counts against reliability. |
| POST | `/jobs/{id}/proof/precheck` | Same as `/proof` | `{ checks }` without submitting (US-39). |
| POST | `/jobs/{id}/proof` | See [Proof](#proof) | The Job (SUBMITTED), or 422 `proof_incomplete`. A double tap gets 409 `already_submitted`. |
| GET | `/jobs/{id}/proofs` | — | Your attempts (the poster and admins see all), with `verdicts`, `decision`, `posterSummary` and `workerFeedback` (US-42). |

An offer object looks like this:

```json
{ "id", "jobId", "status": "queued|sent|accepted|declined|expired|canceled", "expiresAt", "matchReason", "fit",
  "estMinutes", "hourlyRate", "distanceMiles", "travelMinutes" }
```

Offers last 45 s (30 s in demo mode). Count down from `expiresAt`, which is authoritative. `status` can still read `sent` for a moment after `expiresAt`, until the server's timer runs.

### Proof

Send one entry per checklist item. Every submission, including a retry, must include every item; earlier uploads for the same job can be reused.

```json
{ "items": [
  { "checklistItemId": "c1", "photos": [{ "fileURL": "...", "capturedAt": "2026-10-04T15:20:00Z", "latitude": 42.2808, "longitude": -83.743, "phase": "after" }] },
  { "checklistItemId": "c2", "link": "https://github.com/me/site/commit/abc123" },
  { "checklistItemId": "c3", "files": [{ "fileURL": "..." }] },
  { "checklistItemId": "c4", "checkIn": { "latitude": 42.2808, "longitude": -83.743, "at": "2026-10-04T15:25:00Z" } }
] }
```

Rules per evidence type:
- **`PHOTO`:** needs `photoCount` distinct images. If `beforeAfter` is set, also at least one `"phase": "before"` image, and it must differ from the after shots. One image may cover several items of the same job, but a photo used for another job is rejected.
- **`CHECK_IN`:** needs a `checkIn` near the job.
- **`LINK`:** needs a full URL, including `https://`.
- **`FILE`:** needs `files` (a photo also counts).

Each photo's `capturedAt` and each `checkIn.at` must fall between 2 minutes before your `POST /jobs/{id}/start` (when the code was issued) and 2 minutes after the server's clock at submission. In-person photos must carry coordinates.

A 422 lists the problems in `checks`:
- **`missingRequired`**: required items with no evidence.
- **`outsideTimeWindow`**: photos or check-ins taken outside the allowed window.
- **`duplicates`**: photos already used for another job, or the same image as both before and after.
- **`missingUploads`**: uploads that are missing or too large.
- **`outsideGeofence` and `warnings`**: location problems. These don't block submission; a `CHECK_IN` item blocks only when it's missing. The grader and the poster see the warnings. An in-person photo with no GPS, or taken more than 400 m away (1 km in demo mode), turns a pass into `unclear`.

**After submitting**, poll the job until it leaves SUBMITTED. Grading usually takes seconds, but can take up to 15 minutes (3 in demo mode) before it times out to the poster.

- **pass:** every required item passes with confidence ≥ 0.7, the one-time code is visible and matches, and the evidence was on site. The job goes to IN_REVIEW with `reviewDeadline` (24 h, or 2 min in demo mode). If the poster doesn't respond, payment releases automatically (US-47).
- **fail:** the job goes back to IN_PROGRESS with per-item `verdicts`. Read `workerFeedback` from `/proofs`. The worker can retry up to two times, but only before the deadline (US-43).
- **unclear, failed after the retries or past the deadline, or grading timed out:** the job goes to IN_REVIEW with `review.requiresPosterAction = true`. `reviewDeadline` is then a 48-hour poster decision window (5 min in demo mode), and nothing auto-releases. If the poster stays silent, the job becomes DISPUTED with the money held. An admin resolves it with `POST /jobs/{id}/resolve`. If no admin acts within 72 hours (10 min in demo mode), a `fail` refunds the poster and any other grade pays the worker. The app should check `review.requiresPosterAction`, not just `reviewDeadline`.

## The Job object

Here is a real poster draft. Every field before `myRole` is in iOS-B's `Job.swift`:

```json
{
  "id": "01M43PVMC01KZ9Y5A7MZGVE46A",
  "title": "Sketch a logo for a coffee shop",
  "description": "Paper sketch of a logo for \"Bean There.\" Any style.",
  "category": "DESIGN",
  "location": { "latitude": 42.2808, "longitude": -83.743, "address": "State St, Ann Arbor, MI" },
  "deadline": "2026-10-04T21:00:00Z",
  "payAmount": 15,
  "currency": "USD",
  "posterPhotos": ["https://<api>/files/uploads/.../01M43PVMC018FR7GVXR2VBSJ3T.jpg?sig=c4006d5f..."],
  "checklist": [
    { "id": "c1", "text": "The finished design is fully visible and legible", "evidenceType": "PHOTO", "photoCount": 1, "required": true, "beforeAfter": false, "angleHint": "Straight on, whole design in frame" },
    { "id": "c4", "text": "Checked in at the job location", "evidenceType": "CHECK_IN", "photoCount": null, "required": true, "beforeAfter": false, "angleHint": null }
  ],
  "status": "DRAFT",
  "worker": null,
  "proof": null,
  "verdicts": [],
  "reviewDeadline": null,
  "createdAt": "2026-10-04T15:00:00Z",
  "matchReason": null,
  "distanceMiles": null,

  "myRole": "poster",
  "allowedActions": ["edit_checklist", "fund", "delete"],
  "poster": { "id": "...", "name": "Jordan K.", "rating": 4.8, "photoURL": null, "reliability": null },
  "estMinutes": 30,
  "radiusMiles": 5,
  "feeAmount": 1.5,
  "totalAmount": 16.5,
  "flags": [],
  "offer": null,
  "challengeCode": null,
  "attempts": { "failed": 0, "maxRetries": 2 },
  "review": null,
  "dispute": null,
  "resolution": null,
  "payment": { "status": "unpaid" },
  "ratings": { "byPoster": null, "byWorker": null },
  "updatedAt": "2026-10-04T15:00:00Z"
}
```

| Extension field | Use |
|---|---|
| `allowedActions` | Which buttons to show: `edit_checklist`, `fund`, `delete`, `cancel`, `update_terms`, `accept`, `decline`, `start`, `withdraw`, `submit_proof`, `approve`, `reject`, `dispute`, `resolve`, `rate`. |
| `myRole` | `poster`, `worker`, `offered` or `admin`. |
| `offer` | For the offered worker: `{ id, expiresAt, estMinutes, hourlyRate, travelMinutes, fit }`. For the poster: `{ id, expiresAt }`. |
| `review` | `{ decision, summary, requiresPosterAction, windowEndsAt }`. |
| `dispute` | `{ itemId, reason, openedBy: "poster" \| "system", openedAt }`. |
| `resolution` | `{ outcome: "release" \| "refund", by, note, at }`. |
| `payment.status` | `unpaid`, `held`, `releasing`, `paid`, `refunding` or `refunded`. |
| `proof.items[]` | `{ checklistItemId, photoURLs, beforePhotoURLs, afterPhotoURLs, link, fileURLs, checkedInAt, note }`. |
| `verdicts[]` | `{ checklistItemId, pass, verdict: pass\|fail\|unclear, confidence, explanation }`. |

## Payments

`POST /jobs/{id}/fund` returns a FundingSession plus `provider` and `job`:

```json
{ "provider": "stripe", "paymentIntentId": "pi_...", "paymentIntentClientSecret": "pi_..._secret_...",
  "customerId": null, "ephemeralKeySecret": null, "publishableKey": "pk_test_...", "job": { "...": "..." } }
```

- **Stripe:** present PaymentSheet. For jobs from `POST /jobs`, only the webhook moves the job to FUNDED, so run `stripe listen` locally. Only the checkout's `GET /jobs/{uuid}` poll asks Stripe directly.
- **`provider: "fake"`:** the job is already FUNDED.
- **USDC:** returns 501 `rail_unavailable`.
- **Funding guard:** a checklist without a required photo, link or file item gets 409 `checklist_incomplete`.

| Method | Path | Notes |
|---|---|---|
| GET | `/wallet/earnings` | `{ available, pending, currencies: [{ currency, pending, releasing, paid }], payouts: { stripeConnected, payoutsEnabled }, items: [{ jobId, title, amount, currency, status, jobStatus, rail, reference, updatedAt }] }` (US-53/54/55). |
| POST | `/wallet/connect` | `{ url }`: Stripe Express onboarding, opened in `SFSafariViewController` (US-52). Returns to `bounty://wallet?status=returned`. |
| POST | `/wallet/connect/sync` | Refreshes `payoutsEnabled` after the user returns. |

When Stripe is on, workers must finish payout setup before they can be matched.

## Push notifications

```json
{
  "aps": { "alert": { "title": "$15 · 10 min · 0.4 mi", "body": "Sketch a logo: Your logo design work (LinkedIn) fits this brief" },
           "sound": "default", "category": "BOUNTY_JOB_OFFER", "mutable-content": 1,
           "interruption-level": "time-sensitive", "relevance-score": 1 },
  "type": "offer", "jobId": "...", "offerId": "...", "expiresAt": "2026-10-04T15:00:30Z"
}
```

| `type` | To | When |
|---|---|---|
| `offer` | worker | New offer. Category `BOUNTY_JOB_OFFER`. Accept and Decline call `/offers/{offerId}/respond` (TwinKit) or `/accept` and `/decline`. Open with `GET /offers/{offerId}`. |
| `offer_closed`, `job_canceled` | worker | The job you were offered ended unfilled, or the poster canceled. |
| `offer_accepted`, `worker_withdrew`, `no_match_yet` | poster | Matching news. |
| `proof_ready`, `proof_needs_decision` | poster | Proof passed AI review, or needs your decision (US-44). |
| `proof_passed`, `proof_failed`, `proof_escalated` | worker | AI result. |
| `disputed`, `resolved`, `work_rejected` | both / worker | Dispute lifecycle. |
| `deadline_missed`, `unmatched_refund` | both / poster | Deadline refunds (US-48). |
| `paid`, `refunded` | worker / poster | Money moved. |

## Demo tools

These exist in local dev, and in `DEMO_MODE` with `x-demo-key`.

| Method | Path | Body | Use |
|---|---|---|---|
| POST | `/demo/jobs/{id}/fund` | — | Fund a draft with no payment sheet. |
| POST | `/demo/offer` | `{ "jobId", "handle" }` or `{ "jobId", "userId" }` | Send a job straight to one phone. The job must be FUNDED with no offer out. Matching offers a funded job at once, so this works when nobody else is eligible, or after the current offer ends. |
| POST | `/demo/jobs/{id}/fast-forward` | — | Fire the job's next timer now. |
| GET | `/demo/jobs/{id}/explain` | — | Why each user was or wasn't matched. |

Admins only, always available:
- `GET /admin/disputes` lists open disputes.
- `POST /jobs/{id}/resolve` with `{ "outcome": "release" | "refund", "note" }` settles a DISPUTED job.

## What the app needs next

**iosA / TwinKit (on `main`):**
1. Set `BOUNTY_API_BASE_URL` in `Config/Local.xcconfig` (a LAN IP or HTTPS URL). Empty keeps the app on sample data.
2. Register the device: after `registerForRemoteNotifications`, call `POST /me/devices` on every launch, with `env` `sandbox` for Xcode builds and `production` for TestFlight. TwinKit doesn't have this call yet.
3. In `PushNotificationManager`, read `offerId` from `userInfo`. Accept and Decline should call `OfferService.respond(to:decision:)`. Treat 409 `offer_not_current` as "already taken" (US-26).
4. LinkedIn: register `bounty://oauth/linkedin` in the LinkedIn app. If LinkedIn rejects custom schemes, switch to `/auth/linkedin/start`.
5. Show the import result by polling `GET /twin` (`ingest.status` / `ingest.error`) after `/profile/ingest`.
6. Jobs, proof capture and review screens still use sample data. Wire them to the camelCase routes above, using `allowedActions` for buttons.

**Payments checkout (`PaymentCheckoutView`):**
1. Point `BOUNTY_PAYMENTS_BASE_URL` at this backend.
2. Send `Authorization: Bearer <access_token>` from TwinKit's `SessionStore` on `POST /payment-sheet` only. Deployed stages require it.
3. Optionally add `location { latitude, longitude, address }` to `FundingDraft`, so in-person jobs match the right place.
4. Pay must be $5 to $1000, and the deadline 30 minutes to 30 days away. Check both in the form so users don't get a 400.

**iOS-B's networking (`JobsAPI.swift`), if it's adopted:**
- Use `.iso8601` dates.
- Demo handles must be lowercase.
- `description` is required on `POST /jobs`.
- Add `headers` to `PresignedUpload`.
- Add `provider` to `FundingSession`.
