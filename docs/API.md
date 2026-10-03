# Bounty Twin API

The contract between the iOS app and the backend (`backend/`). The Job JSON matches `Bounty/Models/Job.swift` on the `iOS-B` branch field for field, so the app can decode it as is. Fields the app doesn't know yet are listed as extensions and can be adopted one at a time.

For how the backend works inside, see [BACKEND.md](BACKEND.md). For how to run it, see [backend/README.md](../backend/README.md).

## Conventions

| Topic | Rule |
|---|---|
| Base URL | Local: `http://<laptop-ip>:8787`. Deployed: the `ApiUrl` output of `cdk deploy`. |
| Auth | `Authorization: Bearer <token>` on every route except `/health`, `/auth/*`, `/files/*` and webhooks. Tokens last 30 days. |
| Bodies | JSON. Send `Content-Type: application/json`. |
| Money | Dollars as JSON numbers (`15`, `16.5`), decoded as `Decimal`. The poster pays `payAmount` plus a 10% fee. Minimum $5. |
| Distance | Miles. |
| Location | `{ "latitude", "longitude", "address" }`. A job `location` of `null` means remote. |
| Dates | ISO-8601 without fractional seconds: `2026-10-04T21:00:00Z`. Use `.iso8601` for both `JSONDecoder` and `JSONEncoder`. |
| Enums | Uppercase, exactly as in `Job.swift`: `JobStatus`, `JobCategory`, `EvidenceType`, `PayCurrency`. |
| Errors | `{ "error": "<code>", "message": "<text for the user>" }`. Switch on `error`; show `message`. |
| Updates | Mutations return the updated Job. Poll `GET /jobs/{id}` every 2 s on screens that wait for the server; push notifications cover the rest. |

### Error codes

| HTTP | `error` | Meaning |
|---|---|---|
| 400 | `invalid_request`, `bad_request`, `unknown_upload`, `unsupported_type`, `location_required` | Fix the request; `message` says what is wrong. |
| 401 | `unauthorized` | Missing or expired token. Sign in again. |
| 403 | `forbidden` | Not your job, offer or action. |
| 404 | `not_found` | Unknown or not visible to you. |
| 409 | `invalid_transition` | Not allowed in the job's current status. Refresh the job. |
| 409 | `offer_not_current` | Someone else got the job, or the offer moved on (US-26 "already taken"). |
| 409 | `offer_expired` | The server's expiry passed, even if the device countdown didn't. |
| 409 | `not_enough_time`, `deadline_passed`, `window_closed`, `already_done`, `locked`, `checkout_started`, `already_funded`, `busy` | See `message`. `busy` means retry. |
| 422 | `too_far` | Check-in more than 200 m from the job (500 m in demo mode). |
| 422 | `proof_incomplete` | Proof failed the server checks. The body includes `checks` (see Proof). |
| 501 | `rail_unavailable`, `not_configured` | USDC funding, or Stripe/LinkedIn not set up on this server. |

## Sign-in (US-01)

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/auth/demo` | `{ "handle": "judge", "displayName": "Judge" }` | `{ token, userId }`. Only in local dev and `DEMO_MODE`. The same handle always gets the same account. Handle `admin` is an admin. |
| GET | `/auth/linkedin/start` | — | Open in `ASWebAuthenticationSession` with callback scheme `bountytwin`. Ends at `bountytwin://auth?token=...` or `bountytwin://auth?error=linkedin_failed`. |
| POST | `/auth/apple` | `{ "identityToken": "<JWT from ASAuthorizationAppleIDCredential>", "fullName": "Alan Roybal" }` | `{ token, userId }`. Apple sends the name only on the first sign-in, so pass it then. |
| GET | `/me` | — | Profile, payout status, and reliability stats (US-58). |
| PATCH | `/me` | `{ "displayName": "..." }` | Profile. |
| POST | `/me/devices` | `{ "token": "<hex APNs token>", "env": "sandbox" }` | Use `env` `sandbox` for Xcode builds and `production` for TestFlight. |

## Screens and the calls they make

| # | Screen (MVP cut) | Calls | Stories |
|---|---|---|---|
| 1 | Welcome | `POST /auth/demo`, `GET /auth/linkedin/start`, `POST /auth/apple` | US-01 |
| 2 | Profile import | `POST /uploads/presign` → PUT file → `POST /twin/ingest`, then poll `GET /twin` | US-02, US-03 |
| 3 | Twin setup and review | `GET /twin`, `POST /twin/skills`, `DELETE /twin/skills/{normName}` | US-04, US-05, US-08 |
| 4 | Preferences and calendar | `PUT /twin/prefs`, `PUT /twin/availability`, `POST /me/devices` | US-06, US-07 |
| 5 | Home | `GET /offers/current`, `GET /jobs/working`, `GET /jobs/mine`, `GET /twin` (readiness), `GET /wallet/earnings` | — |
| 6 | Jobs list | `GET /jobs/working` (Working, Completed), `GET /jobs/mine` (Posted) | US-17 |
| 7 | Job detail and timeline | `GET /jobs/{id}`, `GET /jobs/{id}/timeline`; buttons from `allowedActions` | US-17, US-49 |
| 8 | Create job | `POST /uploads/presign` (photos), `POST /jobs` | US-11, US-12, US-13 |
| 9 | Checklist review | `PUT /jobs/{id}/checklist`, `POST /jobs/{id}/checklist/regenerate` | US-14 |
| 10 | Checkout | `GET /jobs/{id}/quote`, `POST /jobs/{id}/fund` | US-15, US-16 |
| 11 | Full-screen offer | `GET /offers/current`, `POST /offers/{id}/accept`, `POST /offers/{id}/decline` | US-22–US-26, US-31 |
| 12 | Proof capture and review | `POST /jobs/{id}/start`, `POST /uploads/presign`, `POST /jobs/{id}/proof/precheck`, `POST /jobs/{id}/proof` | US-34–US-43 |
| 13 | Requester proof review | `GET /jobs/{id}`, `GET /jobs/{id}/proofs`, `POST /jobs/{id}/approve`, `/reject`, `/dispute` | US-44–US-46, US-50 |
| 14 | Earnings | `GET /wallet/earnings`, `POST /wallet/connect`, `POST /wallet/connect/sync` | US-52–US-55 |

## Uploads

Every file (job photos, proof photos, résumés, proof files) uses the same two steps:

1. `POST /uploads/presign` with `{ "contentType": "image/jpeg" }`. Allowed types are `image/jpeg`, `image/png`, `image/webp`, `image/heic`, `application/pdf` and `application/zip`.
2. `PUT` the bytes to `uploadURL` with exactly the returned `headers`. Then refer to the file by `fileURL`, or by `blobKey`.

```json
{
  "uploadURL": "https://...presigned...",
  "method": "PUT",
  "headers": { "content-type": "image/jpeg" },
  "expiresAt": "2026-10-04T15:05:00Z",
  "fileURL": "https://<api>/files/uploads/<you>/<id>.jpg?sig=...",
  "blobKey": "uploads/<you>/<id>.jpg"
}
```

`fileURL` never expires, so you can store it (for example in `posterPhotos`) and load it with `AsyncImage`. It redirects to a short-lived download link.

Photo rules:
- Send JPEG, with the longest side about 1600 px or less.
- The limit is 5 MB per photo and 20 MB per file.
- The AI grader can't read HEIC.

## Twin (US-02 to US-08)

| Method | Path | Body | Notes |
|---|---|---|---|
| GET | `/twin` | — | Skills, sources, prefs, availability, `ingest` status and `readiness`. |
| POST | `/twin/ingest` | `{ "fileURL": "...", "kind": "resume_pdf" \| "linkedin_pdf" \| "linkedin_zip" }` | Returns 202 with `ingest.status: "processing"`. Poll `GET /twin` until it is `done` or `failed`. On failure, `ingest.error` is a message to show the user. |
| POST | `/twin/skills` | `{ "name": "Calculus tutoring", "level": 4, "category": "tutoring" }` | Adds a skill, edits one, or restores a deleted one, matched by name. |
| DELETE | `/twin/skills/{normName}` | — | `normName` comes from `GET /twin`. Deleted skills stay deleted when you import again. |
| PUT | `/twin/prefs` | Any of `minPay`, `maxRadiusMiles`, `blockedCategories`, `remoteOk`, `inPersonOk`, `tz`, `quietHours {start,end}` or `null`, `base {latitude,longitude}` or `null` | Set `base` from the device location. Distance is measured from it. |
| PUT | `/twin/availability` | `{ "tz": "America/Detroit", "weekly": "<168 chars of 0/1>", "busy": [{ "start", "end" }] }` | Calendar data stays on the phone. `weekly[day*24+hour]` with Monday = 0, in `tz`. `busy` holds EventKit busy blocks for the next 14 days. |

Each skill looks like this:

```json
{ "normName": "logo design", "name": "Logo design", "category": "design", "level": 4, "confidence": 0.94,
  "userEdited": false, "sources": [{ "kind": "linkedin", "label": "LinkedIn", "evidence": "Graphic Designer at Michigan Daily" }] }
```

Show the source `label` as "From LinkedIn". The labels are `LinkedIn`, `Résumé`, `Email` and `Added by you`.

`readiness` is `{ ready, missing, recommended }`.
- `missing` can contain `skills`, `notifications` and `payouts` (only when Stripe is on). Any of these blocks matching.
- `recommended` can contain `location` and `availability`.

## Jobs

### Poster

| Method | Path | Body | Notes |
|---|---|---|---|
| POST | `/jobs` (alias `/jobs/create`) | `NewJobDraft`: `title`, `description`, `category`, `location` (or `null`), `deadline`, `payAmount`, `currency`, `posterPhotos` (fileURLs), and optional `radiusMiles` | Returns 201 with a DRAFT Job and an AI-generated checklist. The deadline must be 30 minutes to 30 days away. |
| GET | `/jobs/mine` | — | Jobs you posted, newest first. |
| GET | `/jobs/{id}` | — | Visible to the poster, the assigned worker, the worker currently being offered the job, and admins. |
| PATCH | `/jobs/{id}` | Any `NewJobDraft` fields | DRAFT only, before checkout. |
| PUT | `/jobs/{id}/checklist` | `[ChecklistItem]` or `{ "checklist": [ChecklistItem] }` | DRAFT only. App-made ids (UUIDs) are kept. Fields you leave out keep their old values. In-person jobs always keep a `CHECK_IN` item. |
| POST | `/jobs/{id}/checklist/regenerate` | — | Asks the AI again. |
| DELETE | `/jobs/{id}` | — | Drafts only. |
| GET | `/jobs/{id}/quote` | — | `{ payAmount, feeAmount, totalAmount, currency }` (US-15). |
| POST | `/jobs/{id}/fund` | — | Returns a FundingSession (see Payments). Locks price and checklist. |
| POST | `/jobs/{id}/cancel` | — | Before a worker accepts only (US-18). Full refund. |
| PATCH | `/jobs/{id}/terms` | `{ "deadline": "...", "radiusMiles": 10 }` | While no one has accepted (product rule 7). Restarts matching. |
| POST | `/jobs/{id}/approve` | — | IN_REVIEW, or DISPUTED to drop your dispute. Releases payment (US-46). |
| POST | `/jobs/{id}/reject` | — | Only when the AI failed the work after the worker's retries. Refunds you. |
| POST | `/jobs/{id}/dispute` | `{ "checklistItemId": "c2", "note": "Name isn't legible" }` | During the review window (US-50). |
| POST | `/jobs/{id}/rating` | `{ "stars": 5, "comment": "..." }` | After RELEASED or REFUNDED (US-56/57). |
| GET | `/jobs/{id}/timeline` | — | Every status change: `{ seq, type, status, from, label, actor, at }`. `actor` is `you`, `poster`, `worker`, `platform` or `admin` (US-49). |

### Worker

| Method | Path | Body | Notes |
|---|---|---|---|
| GET | `/offers/current` | — | `{ offer, job }`, or `{ offer: null, job: null }`. |
| GET | `/offers/{id}` | — | Offer status for the outcome screen (US-26): `sent`, `accepted`, `declined`, `expired` or `canceled`. |
| POST | `/offers/{id}/accept` | — | Returns `{ offer, job }`. Exactly one worker wins. A second tap by the winner is a 200. Everyone else gets 409 `offer_not_current`. |
| POST | `/offers/{id}/decline` | — | The job moves to the next match. |
| GET | `/jobs/working` | — | Jobs assigned to you, active and finished. |
| POST | `/jobs/{id}/start` | `{ "latitude", "longitude" }` (in-person) or `{}` (remote) | Check-in. The response has `challengeCode` (for example `K7Q-4MX`), which must be visible in proof photos (US-35/36). |
| POST | `/jobs/{id}/withdraw` | — | Give the job back before submitting. The job goes back to matching, and it counts against your reliability. |
| POST | `/jobs/{id}/proof/precheck` | Same body as `/proof` | Runs the server checks without submitting (US-39). |
| POST | `/jobs/{id}/proof` | See below | Submits for AI review (US-41). Returns the Job (SUBMITTED), or 422 `proof_incomplete`. |
| GET | `/jobs/{id}/proofs` | — | Every attempt with per-item AI results and feedback (US-42). |

Proof body. Use one entry per checklist item, with whatever evidence fits its `evidenceType`:

```json
{
  "items": [
    { "checklistItemId": "c1", "photos": [{ "fileURL": "...", "capturedAt": "2026-10-04T15:20:00Z", "latitude": 42.2808, "longitude": -83.743, "phase": "after" }] },
    { "checklistItemId": "c2", "link": "https://github.com/me/site/commit/abc123" },
    { "checklistItemId": "c3", "files": [{ "fileURL": "..." }] },
    { "checklistItemId": "c4", "checkIn": { "latitude": 42.2808, "longitude": -83.743, "at": "2026-10-04T15:25:00Z" } }
  ]
}
```

- **`PHOTO`:** needs `photoCount` photos taken with the in-app camera after `start`. If `beforeAfter` is true, also send at least one photo with `"phase": "before"`, taken right after starting. The ghost overlay should use it. One photo may cover several items.
- **`CHECK_IN`:** needs a `checkIn` within 200 m of the job (500 m in demo mode).
- **`LINK`:** needs `link`.
- **`FILE`:** needs `files`. A photo also counts.
- **`note`:** optional free text on any item.

A 422 `proof_incomplete` lists the problems in `checks`:

| Field | Problem |
|---|---|
| `missingRequired` | Required items with no evidence. |
| `outsideTimeWindow` | Photos taken before the code was issued, or in the future. |
| `duplicates` | Photos already used as proof for another job. |
| `missingUploads` | Uploads that are missing or too large. |
| `outsideGeofence` and `warnings` | Location problems. These don't block submission, but the grader and the poster see them, and a far-away `CHECK_IN` fails. |

### What happens after submission

1. **AI grading.** The AI grades each item, but the server decides the result:
   - **pass:** every required item passes with confidence ≥ 0.7, the code is visible, and the evidence was captured on site. The job goes to IN_REVIEW and the review window starts (24 h, or 2 min in demo mode). When the window ends, payment releases automatically (US-47).
   - **fail:** the job goes back to IN_PROGRESS. The worker sees `verdicts` and `workerFeedback` and can retry up to two times (US-43). After that, the poster decides.
   - **unclear** (or grading took longer than 15 minutes): the job goes to IN_REVIEW with `review.requiresPosterAction = true`. There is no auto-release.
2. **Poster silence on an unclear result.** If the poster never decides, the job becomes DISPUTED. An admin resolves it with `POST /jobs/{id}/resolve` `{ "outcome": "release" | "refund" }`. If no admin acts within 72 hours, the AI's assessment stands: failed work is refunded and anything else is paid.

## The Job object

Here is a real response for a poster's draft. Every field before `myRole` is in `Job.swift`:

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
| `allowedActions` | Which buttons to show. Values: `edit_checklist`, `fund`, `delete`, `cancel`, `update_terms`, `accept`, `decline`, `start`, `withdraw`, `submit_proof`, `approve`, `reject`, `dispute`, `resolve`, `rate`. The server computes these, so one adaptive Job Detail screen can serve every state. |
| `myRole` | `poster`, `worker`, `offered` or `admin`. |
| `offer` | For the offered worker: `{ id, expiresAt, estMinutes, hourlyRate, travelMinutes, fit }`. For the poster: `{ id, expiresAt }`. Count down from the server's `expiresAt`. |
| `challengeCode` | Only for the assigned worker, from `start` onward. |
| `review` | `{ decision, summary, requiresPosterAction, windowEndsAt }`. |
| `payment.status` | `unpaid`, `held`, `releasing`, `paid`, `refunding` or `refunded`. |
| `flags` | Poster only. Moderation warnings from checklist generation. |
| `checklist[].required`, `.beforeAfter`, `.angleHint` | For the capture screen: the angle guide and the before/after overlay. |
| `proof.items[].beforePhotoURLs`, `.afterPhotoURLs`, `.fileURLs`, `.note` | For the before/after comparison (US-45). |
| `verdicts[].verdict` | `pass`, `fail` or `unclear`. `pass: false` covers both `fail` and `unclear`. |

## Payments

`POST /jobs/{id}/fund` returns the app's `FundingSession` plus `provider` and the updated `job`:

```json
{ "provider": "stripe", "paymentIntentId": "pi_...", "paymentIntentClientSecret": "pi_..._secret_...",
  "customerId": null, "ephemeralKeySecret": null, "publishableKey": "pk_test_...", "job": { "...": "..." } }
```

- **`provider: "stripe"`:** present PaymentSheet (Apple Pay or card). Stripe's webhook then moves the job to FUNDED. Poll `GET /jobs/{id}` until it does.
- **`provider: "fake"`** (local dev and demo seeds): the job is already FUNDED, so skip the sheet.
- **USDC:** returns 501 `rail_unavailable` until the Base Sepolia escrow is built.

| Method | Path | Notes |
|---|---|---|
| GET | `/wallet/earnings` | `{ available, pending, currencies: [{ currency, pending, releasing, paid }], payouts: { stripeConnected, payoutsEnabled }, items: [{ jobId, title, amount, currency, status, jobStatus, rail, reference, updatedAt }] }` (US-53/54/55). |
| POST | `/wallet/connect` | `{ url }`. Open it in `SFSafariViewController` for Stripe Express onboarding (US-52). Stripe returns the user to `bountytwin://wallet?status=returned`. |
| POST | `/wallet/connect/sync` | Refreshes `payoutsEnabled` from Stripe after the user returns. |

When Stripe is on, workers must finish payout setup before they can be matched (product rule 2).

## Push notifications

APNs payloads:

```json
{
  "aps": { "alert": { "title": "$15 · 10 min · 0.4 mi", "body": "Sketch a logo: Your logo design work (LinkedIn) fits this brief" },
           "sound": "default", "category": "BOUNTY_JOB_OFFER", "mutable-content": 1,
           "interruption-level": "time-sensitive", "relevance-score": 1 },
  "type": "offer",
  "jobId": "01M43PVMC01KZ9Y5A7MZGVE46A",
  "offerId": "01M43PVMC01KZ9Y5A7MZGVE46A-r1-1",
  "expiresAt": "2026-10-04T15:00:30Z"
}
```

| `type` | To | When |
|---|---|---|
| `offer` | worker | New offer. Category `BOUNTY_JOB_OFFER`. Accept calls `POST /offers/{offerId}/accept`; Decline calls `/decline`. |
| `offer_closed` | worker | The job you were being offered expired unfilled. |
| `offer_accepted` | poster | A worker accepted. |
| `job_canceled` | worker | The poster canceled while you had the offer. |
| `worker_withdrew` | poster | Your worker gave the job back. |
| `no_match_yet` | poster | Nobody accepted in the first round. |
| `proof_ready`, `proof_needs_decision` | poster | Proof passed AI review, or needs your decision (US-44). |
| `proof_passed`, `proof_failed`, `proof_escalated` | worker | AI result. |
| `disputed`, `resolved`, `work_rejected` | both or worker | Dispute lifecycle. |
| `deadline_missed`, `unmatched_refund` | poster and worker, or poster | Deadline refunds (US-48). |
| `paid` | worker | Bounty sent. |
| `refunded` | poster | Refund sent. |

Every push includes `jobId`. Route to the job detail screen for that id.

## Job lifecycle from the app's side

```text
Poster:  POST /jobs → PUT /jobs/{id}/checklist → GET /quote → POST /fund → (FUNDED → OFFERED)
Worker:  push "offer" → POST /offers/{id}/accept (Face ID on device) → (ACCEPTED)
Worker:  POST /jobs/{id}/start → camera + uploads → POST /proof/precheck → POST /proof → (SUBMITTED)
Server:  AI grading → IN_REVIEW (push proof_ready) or IN_PROGRESS (push proof_failed, retry)
Poster:  POST /approve, or do nothing until reviewDeadline → (RELEASED) → push "paid" to worker
```

## Demo tools (local dev and `DEMO_MODE` only)

| Method | Path | Body | Use |
|---|---|---|---|
| POST | `/demo/jobs/{id}/fund` | — | Fund a draft with no payment sheet, even on a Stripe stage. |
| POST | `/demo/offer` | `{ "jobId", "handle": "judge" }` or `{ "jobId", "userId" }` | Send a funded job straight to one phone, with a real "why you" line. |
| POST | `/demo/jobs/{id}/fast-forward` | — | Fire the job's next timer now: offer expiry, review window, grading or dispute timeout, or deadline. |
| GET | `/demo/jobs/{id}/explain` | — | Why each user was or wasn't matched. |
| GET | `/admin/disputes` | — | Open disputes (admins only). |

## Changes the iOS app needs

1. Set `JSONDecoder.dateDecodingStrategy` and `JSONEncoder.dateEncodingStrategy` to `.iso8601`.
2. Register the URL scheme `bountytwin`. It's used for the LinkedIn sign-in redirect and the Stripe onboarding return.
3. After `registerForRemoteNotifications`, call `POST /me/devices` with `env` set to `sandbox` for Xcode builds and `production` for TestFlight. Mixing these up is the most common reason pushes don't arrive.
4. In `PushNotificationManager`, read `offerId` from `userInfo` as well as `jobId`. The Accept action should call `POST /offers/{offerId}/accept` and treat 409 `offer_not_current` as "already taken" (US-26).
5. Point the `JobsAPI` methods at:
   - `presignUpload` → `POST /uploads/presign`
   - `createJob` → `POST /jobs`
   - `updateChecklist` → `PUT /jobs/{id}/checklist`
   - `startFunding` → `POST /jobs/{id}/fund`
   - `job` → `GET /jobs/{id}`
   - `myJobs` → `GET /jobs/mine`
   - `approve` → `POST /jobs/{id}/approve`
   - `dispute` → `POST /jobs/{id}/dispute` with `{ checklistItemId, note }`

   `PresignedUpload` maps to `uploadURL` and `fileURL`. Also send the returned `headers` with the PUT.
6. When `FundingSession.provider == "fake"`, skip PaymentSheet.
7. Adopt extensions as screens need them. The cheapest high-value ones are `allowedActions`, `offer.expiresAt`, `challengeCode`, `review`, `checklist[].beforeAfter` and `checklist[].angleHint`.
8. Camera capture: attach `capturedAt` and GPS to every photo, and make sure the one-time code is visible in the frame.
