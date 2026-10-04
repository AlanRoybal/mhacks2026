# Bounty Twin — Backend Design (as built)

This describes the backend in `backend/` as it exists now, why it is built this way, and what is still missing. The API the app calls is in [API.md](API.md); how to run and deploy is in [backend/README.md](../backend/README.md).

---

## 1. Core ideas

1. **One API and one worker.**
   - All HTTP routes live in a single Hono app (`src/api/app.ts`). It runs as one Lambda behind an HTTP API, or as a local Node server.
   - Everything asynchronous runs in a second Lambda (`src/handlers/worker.ts`): effects, timers, background tasks and the sweep. That's fewer moving parts than one function per job, and the same code runs on a laptop.
2. **The state machine is a pure function.**
   - `transition(job, event, ctx)` in `src/domain/jobMachine.ts` either returns `{ to, patch, effects }` or throws `TransitionError` with a stable code.
   - It does no I/O, reads no clock and uses no randomness, which is why it can be tested exhaustively. Its tests include a 10,000-run randomized walk.
3. **Transactional outbox.**
   - `applyEvent` (`src/services/jobs.ts`) writes the new job and an append-only ledger row in one DynamoDB transaction, conditional on the version it read.
   - The ledger row lists the effects to run. Deployed, the ledger table's stream drives the worker. Locally, effects run in-process right after the commit.
   - Money only moves through the `payout` and `refund` effects, never directly from a request.
4. **Timers are proposals; state is the truth.**
   - Offer expiry, review windows, deadlines, rematches, grading timeouts and dispute timeouts are one-shot EventBridge Scheduler schedules (local: persisted `setTimeout`).
   - When one fires, it proposes an event. The state machine rejects it if it is stale or early, and an early fire is rescheduled. Nothing ever cancels a timer.
   - A one-minute **sweeper** re-fires anything overdue and retries unrecorded payouts and refunds. If a timer or effect is lost, the job still finishes.
5. **Ports with local and AWS adapters.**
   - Store (memory or DynamoDB), scheduler, blobs (local signed URLs or S3), push (console or APNs), AI (fake, Anthropic or Bedrock), embeddings (hash or Titan), and payments (fake, Stripe or USDC placeholder).
   - `npm run dev` needs no accounts, and every adapter has a test double.
6. **The app's model is the wire contract.**
   - `Job.swift` on the iOS-B branch defines the JSON: `id`, `status`, `payAmount` in dollars, `location` `null` for remote, uppercase enums, and second-precision ISO dates.
   - `src/api/wire.ts` maps internal records (integer cents, km, `state`) to that shape and adds extension fields the app can adopt.

---

## 2. Architecture

```
 iOS app ──HTTPS/JWT──▶ API Gateway (HTTP API) ──▶ api Lambda (Hono, every route)
   ▲                                                   │  applyEvent: job + ledger row, version-checked
   │ APNs (HTTP/2, .p8 token)                          ▼
   │                                   DynamoDB: jobs · users · offers · proofs · ledger · kv
   │                                                   │ ledger stream (INSERT, in order per job)
   │                                                   ▼
   └─────────────────────────────────────────── worker Lambda
                                                 ├─ effects: match, offer.next, push, schedule,
                                                 │           grade, payout, refund, stats, offer.status
                                                 ├─ timers (EventBridge Scheduler one-shot)
                                                 ├─ tasks (résumé import, async invoke from the API)
                                                 └─ sweep (EventBridge rule, every minute)

 Effects that fail every retry → SQS dead-letter queue → CloudWatch alarm ("money is stuck")
 External: Claude (Anthropic API or Bedrock), Titan embeddings, Stripe (PaymentIntents, Connect, webhooks), S3
```

---

## 3. Data model (DynamoDB, one table per entity)

| Table | Keys | Indexes | Holds |
|---|---|---|---|
| jobs | `jobId` | `byPoster (posterId, createdAt)`, `byWorker (workerId, updatedAt)` | The job, its state and `version` (optimistic lock), checklist, current offer, capture key, review, dispute and payment references |
| users | `userId` | — | Profile, twin (skills with sources, embedding, import status), prefs, availability, devices, Stripe account, stats, `version` |
| offers | `offerId` | `byJob (jobId, createdAt)`, `byWorker (workerId, createdAt)` | Ranked candidates per matching round: fit, "why you", estimate, status |
| proofs | `jobId`, `proofId` | — | Evidence items, server checks, stored AI grade |
| ledger | `jobId`, `seq` | stream (NEW_IMAGE) | Append-only history; `seq` equals the job version; carries the effects |
| kv | `key` | TTL `expiresAt` | Identity → user mappings, effect claims, photo ETag registry, Stripe event IDs and account mappings |

Conventions:
- Money is stored as integer cents and converted to dollars only on the wire.
- Times are UTC ISO strings.
- Optional fields are omitted, not stored as null.

---

## 4. Job state machine

```
DRAFT ──fund──▶ FUNDED ──offer──▶ OFFERED ──accept──▶ ACCEPTED ──start──▶ IN_PROGRESS ──submit──▶ SUBMITTED
                  ▲  │               │                    │                    │                       │
                  │  │ decline/expire└──▶ FUNDED (next)   │ withdraw ──▶ FUNDED │ withdraw ──▶ FUNDED   │ grade
                  │  │ no candidates ──▶ FUNDED + rematch timer                                         ▼
                  │  └ cancel / deadline ──▶ REFUNDED                       pass ──▶ IN_REVIEW (window) ──▶ RELEASED
                  │                                                         fail ──▶ IN_PROGRESS (retry ≤ 2)
                  │                                       unclear / out of retries / timeout ──▶ IN_REVIEW (poster decides)
ACCEPTED / IN_PROGRESS ──deadline──▶ REFUNDED             IN_REVIEW ──dispute──▶ DISPUTED ──▶ RELEASED | REFUNDED
```

`OFFERED` holds exactly when `currentOffer` is set. Offers go out one at a time; a decline or expiry returns the job to FUNDED and asks for the next candidate.

### Product rules (the open questions in the user stories doc, now decided)

| # | Rule | Decision |
|---|---|---|
| 1 | Checklist locking | Editable only as a DRAFT before checkout starts. `POST /fund` records the PaymentIntent and locks the price and checklist. |
| 2 | Payout readiness | When Stripe is on, workers must finish Connect onboarding before they can be matched. |
| 3 | Offer races | Exactly one winner, enforced by the conditional write. A repeat tap by the winner is a success; everyone else gets `offer_not_current`. |
| 4 | Cancel after acceptance | Not allowed (US-18 says before acceptance). The worker can withdraw, or the deadline refunds. |
| 5 | Worker withdrawal | Allowed from ACCEPTED or IN_PROGRESS. The job re-opens, the worker is excluded, and it counts against reliability. |
| 6 | Retry limit | Per submission: the worker can retry two failed gradings. The third failure goes to the poster, who may reject (refund) or approve. |
| 7 | No match | Rematch rounds every 10 minutes (1 in demo mode). The poster can extend the deadline or widen the radius, or cancel. Unmatched at the deadline means a refund. |
| 8 | Platform fee | 10% on top, shown by `GET /quote`; $5 minimum bounty. |
| 9 | AI authority | The AI grades each item; code decides. Pass needs every required item passing with confidence ≥ 0.7 and on-site evidence. Photos and videos must be signed in-app captures. Unclear results never auto-release. |
| 10 | Demo scope | Fake rail and Stripe are done. USDC, Gmail, Live Activities and the rich notification extension are not. |

Further rules found in review:
- **Grading timeout:** grading that hasn't finished in 15 minutes goes to the poster.
- **Silent poster:** if the poster never decides on an unclear grade, the job becomes a dispute. An admin resolves it; after 72 hours the AI's assessment stands.
- **Enough time:** offers and accepts require enough time before the deadline to do the work.
- **No timer slack:** timers have zero early tolerance, so accept/expire and submit/deadline never overlap.

---

## 5. Flows

### Twin
- **Import:** `POST /uploads/presign`, PUT the file, then `POST /twin/ingest` starts a background task.
  - PDFs go to Claude as document blocks. LinkedIn ZIPs are unzipped and only the relevant CSVs are sent.
  - Structured output returns skills with level, confidence and evidence.
- **Merging:** skills are merged by normalized name and each source is recorded. User edits always win, and deleted skills stay deleted. The twin embedding is then recomputed.
- **Readiness:** `readiness` lists what blocks matching (skills, push token, payouts) and what would improve it (location, availability).

### Matching (`src/services/matching.ts`)
1. **Hard filters:** readiness, minimum pay, blocked categories, remote or in-person, radius from the worker's `base`, and a calendar free window long enough for the work plus travel.
2. **Pre-rank:** `0.6 × skill similarity + 0.2 × reliability + 0.2 × proximity`, using cosine similarity of embeddings computed in memory (no vector database needed at this scale).
3. **Re-rank:** Claude scores the top 8 for fit and writes the "why you" line. Fits under 40 are dropped.
4. **Offers:** stored per round with deterministic IDs, so re-running a round never duplicates them. They go out in rank order. Quiet hours skip a worker for now.

### Proof and grading (`proof.ts`, `grading.ts`)
- **Server checks before submitting:**
  - required coverage, including photo counts and before/after
  - uploads present and within size
  - photos and videos taken with the Bounty camera (signed capture) after the worker started
  - no photo reused from another job (MD5 ETag registry)

  Location problems are warnings.
- **Grading:** Claude vision grades each non-check-in item. Check-ins are verified from GPS by the server. Code applies the decision rule above. The grade is stored on the proof, so a retried effect never re-grades.

### Payments (`src/payments`, `services/payments.ts`)
- **Fake rail:** funding confirms immediately and payouts or refunds return fake references. Used for local dev and demo seeds.
- **Stripe rail ("separate charges and transfers"):**
  - **Funding:** a PaymentIntent for `bounty + fee` with `transfer_group = jobId`. The signed webhook confirms funding and checks the amount and PaymentIntent. A payment that a job can't accept is refunded.
  - **Payouts:** a transfer to the worker's Express account. It uses an idempotency key, checks the transfer group first (keys expire after about 24 hours), and sets `source_transaction` so demo payouts don't wait for settlement.
  - **Refunds:** return the full charge.
- **USDC:** returns 501 until the payments workstream adds the Base Sepolia escrow behind the same `PaymentRail` interface.

### Push (`src/push`)
- APNs over HTTP/2 with token auth. Each device is routed to the sandbox or production host based on its `env`.
- Offers use the app's `BOUNTY_JOB_OFFER` category with time-sensitive interruption, and carry `jobId`, `offerId` and `expiresAt`.
- Dead tokens are pruned.
- Stats and push effects run at most once per ledger row, so a retry can't double-count or re-notify.

---

## 6. AI layer (`src/ai`)

| Task | Effort | Fallback when Claude is unavailable |
|---|---|---|
| Profile extraction | medium | None: the import is marked failed with a readable message, and the user retries |
| Checklist | low | Category template (the poster can edit it) |
| Re-rank and "why you" | low | Score order with a templated reason |
| Vision grading | medium | Every item "unclear", so the poster decides |

- **Model:** Claude Opus 5.5 (`claude-opus-5-5`; `anthropic.claude-opus-5-5` on Bedrock). Override it with `AI_MODEL`.
- **Outputs:** structured outputs validated with zod. `refusal` stop reasons are handled, and the Claude API path enables server-side refusal fallbacks.
- **User content:** job text, résumés, links and photo text are passed as delimited data. The grading prompt tells the model to ignore instructions in evidence, and the code-side decision rule limits what a manipulated verdict could do.
- **Offline mode:** `AI_PROVIDER=fake` runs deterministic heuristics with no network. It reads LinkedIn `Skills.csv` for real, but returns sample skills for PDFs.

---

## 7. Local development and testing

- **`npm run dev`:** memory store snapshotted to `.data/`, inline effects, persisted local timers, signed local upload URLs, console push, fake AI and fake payments.
- **`npm run seed`:** seeds any running stage over HTTP.
- **Tests (`npm test`, about 100, all offline):** the state machine with randomized invariants, the store, and every API flow end to end using an in-memory app with a controllable clock and manual timers (`src/testing/`).

---

## 8. Security notes

- **Authorization:** routes check that the caller is the poster, worker or admin, and the state machine checks again. Admins can't resolve disputes on their own jobs.
- **Uploads:** stored under `uploads/<userId>/`. A request can only reference its own uploads. File links are HMAC-signed, and downloads redirect to short-lived presigned URLs.
- **Stripe webhooks:** verified against the raw body. The client's word is never trusted for payment.
- **Demo login and `/demo/*`:** exist only in local dev and `DEMO_MODE`. Don't enable `DEMO_MODE` on a stage with real users.
- **Secrets:** passed as Lambda environment variables from `.env` at deploy time. Move them to Secrets Manager before real users.

---

## 9. Not built yet

| Item | Notes |
|---|---|
| USDC escrow (US-19) | Contract, viem rail and chain confirmation. The payments workstream owns this; plug it into `PaymentRail`. |
| Pick from top 3 (US-20) | The machine has a single current offer. It would need a second offering mode. |
| Raising the pay on an unmatched job | Needs a top-up charge. Today the poster cancels and reposts. |
| Gmail/Outlook skills (US-9), twin chat (US-10) | Stretch. |
| Rich notification extension, Live Activity (US-32/33) | App-side. The push payload already has what they need. |
| App Attest, perceptual photo hashing | Stretch anti-fraud. Exact-duplicate detection exists. |
| Vector database | The in-memory cosine scan is fine for hundreds of workers. Swap in S3 Vectors behind `matching.ts` when that stops being true. |
| Admin UI | `GET /admin/disputes` and `POST /jobs/{id}/resolve` exist; there is no screen. |
