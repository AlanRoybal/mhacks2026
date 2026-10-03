# Bounty Twin — Backend System Design

This is a design sketch, not an implementation. It turns the build plan into concrete services, data shapes and flows, and records the decisions the backend team should make before hour 0.

---

## 1. Core ideas

These five decisions shape everything else.

1. **One API Lambda that holds every route, plus a few worker Lambdas.** All HTTP routes live in one [Hono](https://hono.dev) app deployed as one Lambda. The same app runs locally with `tsx watch`, so you get hot reload instead of a 60-second `cdk deploy` per change. Only the async workers (outbox, timers, chain poller) are separate Lambdas.
2. **The job state machine is a pure function.** `transition(job, event) → { nextState, patch, effects }` does no I/O. It's easy to unit-test, and it's the only code that decides what is legal.
3. **Transactional outbox: state changes and side effects are written together.** Each transition writes the new job *and* a `LedgerEvents` row in one DynamoDB transaction. The ledger row lists the side effects (push, schedule timer, pay out, refund, grade). A DynamoDB Stream on the ledger table triggers the **outbox worker**, which runs those effects. Money moves only from that worker, never from an API request.
4. **Timers are hints; state is the truth.** Offer expiry, review windows, deadlines and re-matching all use one-shot **EventBridge Scheduler** schedules that call one `timers` Lambda. The handler sends an event (`REVIEW_WINDOW_EXPIRED`), and the state machine's guards reject it if it no longer applies. You never need to cancel a timer.
5. **One payment-rail interface, two implementations.** `StripeRail` and `UsdcRail` both implement `fund / release / refund`. The state machine only knows `rail: "stripe" | "usdc"`. If crypto gets cut, you delete one file.

> **Deviation from the plan:** the plan uses Step Functions for the offer cascade. EventBridge Scheduler plus the state-machine guards does the same job with fewer moving parts, works the same way for every timer, and is easy to fake locally with `setTimeout`. Use Step Functions only if someone on the team already knows it well.

---

## 2. Architecture

```
                         ┌──────────────────────────────────────────────┐
 iOS app ──HTTPS/JWT──▶  │ API Gateway (HTTP API)                        │
   ▲                     │   └─ api Lambda (Hono, all routes)            │
   │                     └───────┬───────────────────────┬──────────────┘
   │ APNs                        │ TransactWrite          │ presigned PUT
   │                             ▼                        ▼
   │                ┌──────────────────────┐        ┌──────────┐
   │                │ DynamoDB             │        │ S3       │ resumes, proof photos
   │                │  Users  Jobs  Offers │        └──────────┘
   │                │  Proofs Idempotency  │
   │                │  LedgerEvents ──Stream──┐
   │                └──────────────────────┘  │
   │                                          ▼
   │   ┌──────────────────────────────────────────────────────────────┐
   └───┤ outbox Lambda: runs each ledger event's effects               │
       │   push · schedule · match · grade · payout · refund          │
       └──┬─────────────┬──────────────┬───────────────┬──────────────┘
          │             │              │               │
          ▼             ▼              ▼               ▼
   EventBridge     Bedrock         S3 Vectors      Stripe / Base Sepolia
   Scheduler       (Claude,        (twin + job      (PaymentIntents,
     │             Titan embed)     embeddings)      Transfers, Escrow.sol)
     ▼
   timers Lambda ──▶ applyEvent(jobId, TIMER_EVENT)

   Stripe webhook ─▶ api Lambda /webhooks/stripe ─▶ applyEvent(FUND_CONFIRMED)
   chainPoller Lambda (every 1 min) ─▶ reads Deposited logs ─▶ applyEvent(FUND_CONFIRMED)
```

---

## 3. Repository layout

```
backend/
  infra/
    app.ts                 CDK entry; `-c stage=<name>` gives each developer their own stack
    stack.ts               tables, bucket, lambdas, HTTP API, scheduler group, IAM
  src/
    api/
      app.ts               Hono app; mounts the routers
      lambda.ts            hono/aws-lambda adapter
      auth.ts              JWT middleware, LinkedIn OIDC, Sign in with Apple, demo login
      routes/
        twin.ts            ingest, skills CRUD, prefs, availability
        jobs.ts            create, checklist edit, fund, start, timeline
        offers.ts          accept / decline
        proof.ts           upload URLs, submit
        review.ts          approve, dispute
        wallet.ts          Connect onboarding link, earnings
        webhooks.ts        stripe
        demo.ts            DEMO_MODE only: fast-forward, force-offer, reset
    domain/
      types.ts             zod schemas: Job, Offer, Twin, Proof, LedgerEvent
      jobMachine.ts        pure transition() + guards        ← most important file
      jobMachine.test.ts
      money.ts             fees, integer cents, USDC conversion
      config.ts            durations (real vs demo)
    data/
      ddb.ts               DocumentClient + table names
      jobs.ts              applyEvent(): read → transition → TransactWrite → retry
      users.ts offers.ts proofs.ts
    effects/
      outbox.ts            DynamoDB Stream handler → runEffects()
      runEffects.ts        switch on effect.kind (shared with local inline mode)
    ai/
      claude.ts            Bedrock client + parse helper + refusal handling
      extractSkills.ts     résumé / LinkedIn PDF/ZIP → skills
      checklist.ts         job description → acceptance checklist
      rerank.ts            candidates → ranked list + "why you"
      grade.ts             proof images + checklist → per-item verdicts
      embed.ts             Titan v2 embeddings
    matching/
      match.ts             hard filters → vector recall → score → LLM re-rank
      geo.ts availability.ts
    payments/
      rail.ts              interface PaymentRail
      stripeRail.ts
      usdcRail.ts          viem; arbiter key loaded from Secrets Manager
    push/
      apns.ts              HTTP/2 + ES256 token auth, no SDK
      templates.ts
    scheduler/
      scheduler.ts         interface; EventBridge implementation + local setTimeout implementation
    workers/
      timers.ts            scheduler target
      chainPoller.ts
    local.ts               @hono/node-server + INLINE_EFFECTS + local scheduler
  scripts/
    seed.ts                30 Ann Arbor workers + 30 jobs, embeddings included
contracts/                 Foundry: src/BountyEscrow.sol, test/BountyEscrow.t.sol, script/Deploy.s.sol
```

---

## 4. Data model (DynamoDB)

Use one table per entity. A single-table design is more elegant, but four people learning one key scheme at 3am is a bad trade.

| Table | PK / SK | GSIs | Notes |
|---|---|---|---|
| **Users** | `userId` | `byLinkedinSub`, `byAppleSub` | Profile, twin, prefs, availability, device tokens, `stripeAccountId`, `walletAddress`, reliability stats |
| **Jobs** | `jobId` | `byPoster (posterId, createdAt)`, `byWorker (workerId, updatedAt)`, `byState (state, deadline)` | Has a `version` number for optimistic locking |
| **Offers** | `jobId` / `rank#03` | `byWorker (workerId, sentAt)` | Ranked candidates; status `queued → sent → accepted/declined/expired` |
| **Proofs** | `jobId` / `proofId` | — | Evidence items + AI grade result |
| **LedgerEvents** | `jobId` / `seq` (= job version) | — | Append-only. **Stream enabled (NEW_IMAGE)**, which drives the outbox |
| **Idempotency** | `key` | — | Stripe event IDs, client `Idempotency-Key`s, chain poller cursor. TTL attribute |

### Key shapes (sketch)

```ts
Job {
  jobId, posterId, workerId?,
  title, description, category, photos: string[],
  remote: boolean, location?: { lat, lng, address, radiusM },
  deadline: ISO,
  bountyCents: int,           // what the worker gets
  feeCents: int,              // 10% platform fee, charged to the poster on top
  rail: "stripe" | "usdc",
  state: JobState, version: int,
  checklist: ChecklistItem[], // generated by AI, editable while in DRAFT
  currentOfferId?, offerExpiresAt?,
  challenge?: { code: "K7Q-42", issuedAt },  // one-time code, set on START
  attempts: int,              // AI-fail retries, max 2
  review?: { aiSummary, requiresPosterAction: boolean, windowEndsAt },
  payment: { paymentIntentId?, chargeId?, transferId?, refundId?, depositTx?, releaseTx? },
}

ChecklistItem { id, text, evidence: "photo" | "photo_pair" | "location" | "link" | "file" | "text",
                required: boolean, angleHint? }

Twin (on the User item) {
  skills: [{ name, normName, category, level 1-5, confidence 0-1,
             sources: [{ kind: "linkedin" | "resume" | "email" | "user", evidence }],
             userEdited: boolean, deleted: boolean }],   // deleted = tombstone, so re-ingest doesn't bring it back
  summary, yearsExperience, embeddingVersion,
  prefs: { minPayCents, maxRadiusKm, blockedCategories, remoteOk, inPersonOk, quietHours },
  availability: { tz, weekly: bitset of 168 hours, busy: [{ start, end }] for the next 14 days },
}

LedgerEvent { jobId, seq, type, from, to, actor, at, event, effects: Effect[], inline?: boolean }
```

**Money rule:** use integer cents everywhere. Convert to USDC base units (6 decimals) only inside `usdcRail` (`cents × 10⁴`).

---

## 5. The state machine (`domain/jobMachine.ts`)

```ts
type JobEvent =
  | { type: "FUND_CONFIRMED"; rail; ref }
  | { type: "OFFER_SENT"; offerId; workerId; expiresAt }
  | { type: "OFFER_DECLINED" | "OFFER_EXPIRED"; offerId }
  | { type: "CANDIDATES_EXHAUSTED" }
  | { type: "ACCEPT"; offerId; workerId }
  | { type: "START"; lat?; lng? }
  | { type: "SUBMIT"; proofId }
  | { type: "GRADE_PASS" | "GRADE_UNCLEAR"; proofId; summary }
  | { type: "GRADE_FAIL"; proofId; feedback }
  | { type: "APPROVE" } | { type: "REVIEW_WINDOW_EXPIRED" }
  | { type: "DISPUTE"; itemId; reason } | { type: "RESOLVE"; outcome: "release" | "refund" }
  | { type: "DEADLINE_PASSED" } | { type: "CANCEL" }
  | { type: "PAYOUT_CONFIRMED" | "REFUND_CONFIRMED"; ref };   // record-only, state unchanged

type Effect =
  | { kind: "match" } | { kind: "offer.next" }
  | { kind: "push"; to: userId; template; data }
  | { kind: "schedule"; timer: "offer_expire" | "review_window" | "deadline" | "rematch"; at; data? }
  | { kind: "grade"; proofId }
  | { kind: "payout" } | { kind: "refund" };

function transition(job: Job, ev: JobEvent, ctx: { now, cfg, actor }):
  { to: JobState; patch: Partial<Job>; effects: Effect[] }   // throws InvalidTransition
```

### Transition table

| From | Event | Guard | To | Effects |
|---|---|---|---|---|
| DRAFT | FUND_CONFIRMED | amount matches | FUNDED | `match`, `schedule deadline` |
| DRAFT | CANCEL | actor is poster | — (delete) | — |
| FUNDED / OFFERED | OFFER_SENT | — | OFFERED | `push offer`, `schedule offer_expire` |
| OFFERED | OFFER_DECLINED / OFFER_EXPIRED | `offerId == currentOfferId` | OFFERED | `offer.next` |
| OFFERED | CANDIDATES_EXHAUSTED | — | FUNDED | `schedule rematch (+10m)` |
| OFFERED | ACCEPT | `offerId == currentOfferId`, worker matches, offer not expired | ACCEPTED | `push poster`, start Live Activity |
| FUNDED / OFFERED | CANCEL | poster | REFUNDED | `refund` |
| ACCEPTED | START | worker; in-person: within `radiusM` | IN_PROGRESS | sets `challenge` |
| IN_PROGRESS | SUBMIT | worker, before deadline | SUBMITTED | `grade` |
| SUBMITTED | GRADE_PASS | — | IN_REVIEW | `push poster`, `schedule review_window` |
| SUBMITTED | GRADE_UNCLEAR | — | IN_REVIEW (`requiresPosterAction`) | `push poster` (no auto-release) |
| SUBMITTED | GRADE_FAIL | `attempts < 2` | IN_PROGRESS | `push worker feedback` |
| SUBMITTED | GRADE_FAIL | `attempts ≥ 2` | IN_REVIEW (`requiresPosterAction`) | `push poster` |
| IN_REVIEW | APPROVE | poster | RELEASED | `payout` |
| IN_REVIEW | REVIEW_WINDOW_EXPIRED | `!requiresPosterAction` | RELEASED | `payout` |
| IN_REVIEW | DISPUTE | poster, names a checklist item | DISPUTED | `push admin` |
| DISPUTED | RESOLVE | admin | RELEASED / REFUNDED | `payout` / `refund` |
| ACCEPTED / IN_PROGRESS | DEADLINE_PASSED | — | REFUNDED | `refund`, reliability penalty |
| RELEASED / REFUNDED | PAYOUT_/REFUND_CONFIRMED | — | same | records the transfer/refund ID |

Two consequences of this design:

- **Two workers accepting at once is safe.** Both read version 7. One transaction commits version 8 and the other fails its `version = 7` condition. The retry re-reads, finds the job `ACCEPTED`, and `transition` throws. The API returns `409 offer_taken`.
- **Stale timers do nothing.** For example, `REVIEW_WINDOW_EXPIRED` arriving after the poster approved gets `InvalidTransition`, which is logged and ignored.

### `applyEvent` (`data/jobs.ts`)

```ts
async function applyEvent(jobId, event, actor) {
  for (let attempt = 0; attempt < 3; attempt++) {
    const job = await getJob(jobId);
    const { to, patch, effects } = transition(job, event, ctx(actor));   // may throw
    const next = { ...job, ...patch, state: to, version: job.version + 1, updatedAt: now };
    try {
      await ddb.transactWrite([
        put(JOBS,   next,                              "version = :v", { ":v": job.version }),
        put(LEDGER, { jobId, seq: next.version, type: event.type, from: job.state,
                      to, actor, event, effects, inline: INLINE_EFFECTS }, "attribute_not_exists(seq)"),
      ]);
      if (INLINE_EFFECTS) await runEffects(next, effects);   // local dev only
      return next;
    } catch (e) { if (!isConditionalFailure(e)) throw e; }  // lost the race → re-read
  }
  throw new Conflict();
}
```

---

## 6. Key flows

### 6.1 Onboarding → twin

1. **Sign-in.** iOS opens `ASWebAuthenticationSession` to LinkedIn's authorize URL with `redirect_uri = https://api…/auth/linkedin/callback` and a signed `state`. The callback exchanges the code, verifies the `id_token` against LinkedIn's JWKS (`iss = https://www.linkedin.com/oauth`), upserts the user by `sub`, mints **our own JWT** (HS256, 30 days, using `jose`), and redirects to `bountytwin://auth?token=…`.
   - `POST /auth/apple` verifies an Apple identity token the same way.
   - `POST /auth/demo` (DEMO_MODE only) logs in as a prepared judge profile.
2. **Résumé upload.** `POST /twin/uploads` returns a presigned S3 PUT URL. Then `POST /twin/ingest { s3Key, kind }`:
   - **PDF** (résumé or LinkedIn "Save to PDF"): send it directly to Claude as a `document` block. No PDF parsing library is needed.
   - **LinkedIn ZIP**: unzip in Lambda (`fflate`), keep `Skills.csv`, `Positions.csv`, `Education.csv`, `Certifications.csv`, and send them as text.
   - Use structured output (`messages.parse` with a zod schema) to get `{ skills[], roles[], education[], certifications[], yearsExperience, summary }`.
   - **Merge into the twin** by `normName`. Skills the user edited win, and tombstoned skills stay deleted. Each source is appended to the skill's `sources` list, which is what the "from LinkedIn" chips on the twin screen show.
   - Re-embed the twin and upsert it into S3 Vectors.
3. **Availability.** `PUT /twin/availability` takes `{ tz, weekly[168], busy[] }`. EventKit stays on the device, and only free/busy data leaves the phone.
4. **Twin edits.** `PATCH /twin/skills/:normName` and `DELETE …` set `userEdited` / `deleted` and trigger a re-embed.

**What gets embedded:** a short generated "twin document": the summary, the top skills weighted by confidence, roles, and preferred categories. Optional upgrade: embed **one vector per skill cluster** and take the max similarity, so a person with both a design and a tutoring background matches both kinds of job well.

### 6.2 Posting and funding a job

1. `POST /jobs` creates a DRAFT and calls the **checklist generator** synchronously (low effort, a few seconds). It returns the job with an editable checklist.
   - The prompt asks for *objective, photographable* items and the evidence type for each one.
   - In-person jobs always get a `location` check-in item, and physical jobs get before/after `photo_pair` items with angle hints.
2. `PATCH /jobs/:id/checklist` while the job is in DRAFT.
3. `POST /jobs/:id/fund`:
   - **Stripe:** create a PaymentIntent for `bounty + fee` with `transfer_group = jobId` and `metadata.jobId`, then return the `client_secret` for PaymentSheet / Apple Pay. The `payment_intent.succeeded` webhook triggers `FUND_CONFIRMED`.
   - **USDC:** return `{ contract, jobIdBytes32, amount }`. The poster's wallet calls `approve` + `deposit`. Then `POST /jobs/:id/fund/usdc/confirm { txHash }` lets the server **verify the receipt itself** (correct contract, `Deposited` event, matching amount) and apply `FUND_CONFIRMED` right away. The 1-minute `chainPoller` is the backstop if the app never calls confirm.

### 6.3 Matching (`effects: match`)

```
candidates = Users where
  has device token AND not the poster AND payouts enabled for this job's rail
  AND prefs.minPayCents ≤ bounty AND category ∉ blockedCategories
  AND (remote ? remoteOk : inPersonOk AND haversine ≤ min(prefs.maxRadiusKm, job radius))
  AND hasFreeWindow(availability, now → deadline, estMinutes)

recall  = vector top-20 by cosine(jobEmbedding, twinEmbedding)   (S3 Vectors query with metadata filter)
score   = 0.60·similarity + 0.20·reliability + 0.20·(1 − distance/maxRadius)
rerank  = Claude over the top 8 → [{ workerId, fit 0-100, why ≤ 90 chars citing a skill source, estMinutes }]
offers  = drop fit < 40, write the rest to Offers as rank#01..N (status queued), then run effect offer.next
```

- At hackathon scale (fewer than 100 workers), a brute-force cosine over a `Users` scan is just as fast. Keep S3 Vectors behind a `VectorIndex` interface so the pitch can say "vector search" while a bad network day can't break the demo.
- **Re-rank once per job, not once per twin.** One call that compares candidates is cheaper and ranks better. For the "agent" story, you can say each twin's offer pitch is generated in its own voice. A per-twin agent loop is a Fable/Fetch.ai stretch.
- **Hourly rate** is computed in code: `bounty / estMinutes × 60`. Don't let the LLM do arithmetic you can show on screen.
- `offer.next` takes the next `queued` offer and applies `OFFER_SENT`. That triggers a `push` with category `JOB_OFFER`, `interruption-level: time-sensitive` and `{offerId, jobId}`, and a `schedule offer_expire` at +45s (+30s in demo). If no offers are left, it applies `CANDIDATES_EXHAUSTED`.
- Quiet hours: skip those candidates during the cascade instead of queueing pushes for them.

### 6.4 Accept / decline

- `POST /offers/:offerId/accept` and `…/decline`. The notification action handler on iOS calls these with the JWT from the shared Keychain access group. Face ID is enforced on the device through `.authenticationRequired`.
- Accept → `applyEvent(ACCEPT)`. A `409` means someone else accepted first, or the offer expired, and the app shows "offer no longer available."
- Use an `Idempotency-Key` header so a retried tap can't double-apply.

### 6.5 Doing the job and proof

1. `POST /jobs/:id/start { lat, lng }` → `START`. The guard checks the location for in-person jobs. The server generates the **one-time challenge code** (6 characters, no ambiguous characters like 0/O or 1/I) and stores `issuedAt`.
2. `POST /jobs/:id/proof/uploads { items: [{ checklistItemId, phase, contentType }] }` returns presigned PUT URLs that expire after 5 minutes, at `proofs/{jobId}/{proofId}/{itemId}-{phase}.jpg`.
   - iOS should **downscale to a 1568px long edge, JPEG quality 0.8** before upload. That's the useful vision input size, and it keeps grading fast.
3. `POST /jobs/:id/proof/submit { proofId, items: [{ checklistItemId, s3Key | url | text, phase, capturedAt, lat, lng }] }`. The server checks before accepting:
   - every required item is present
   - `capturedAt ∈ [challenge.issuedAt, now]`
   - photo GPS is within `radiusM` of the job
   - each S3 object exists and is under 5 MB
   - the S3 ETag (MD5) doesn't match any earlier proof, which catches exact-duplicate reuse (a perceptual hash is a stretch goal)
   - Then → `SUBMIT` → effect `grade`.
4. **Grading** (`ai/grade.ts`): one Claude vision call that gets the job, checklist, challenge code and before/after pairs. Structured output:
   ```ts
   { codeVisible: boolean, codeReadAs: string,
     items: [{ itemId, verdict: "pass" | "fail" | "unclear", confidence: 0-1, reason: string }],
     posterSummary: string, workerFeedback: string }
   ```
   **Your code decides the outcome, not the model:**
   - **PASS:** every required item passes with confidence ≥ 0.7, the code is visible on at least one photo, and the server-side geo/time checks passed.
   - **FAIL:** any required item fails with confidence ≥ 0.7.
   - **UNCLEAR:** anything else. It goes to poster review with no auto-release.
   - Store the full grade on the Proof row. The poster's review screen shows it item by item.

### 6.6 Release, refund, payouts

- **`payout` effect:**
  - **Stripe:** `transfers.create({ amount: bounty, destination: worker.stripeAccountId, transfer_group: jobId, source_transaction: chargeId }, { idempotencyKey: "payout:" + jobId })`. `source_transaction` lets the transfer go out before the charge settles, which matters for a 2-minute demo.
  - **USDC:** the arbiter wallet calls `release(jobId, worker)` and waits for 1 confirmation.
  - Then `applyEvent(PAYOUT_CONFIRMED, { ref })`.
- **`refund` effect:** `refunds.create({ payment_intent }, { idempotencyKey: "refund:" + jobId })`, or arbiter `refund(jobId)` on-chain.
- If an effect throws, the stream retries it (bisect on error, at most 3 attempts, then the event goes to an SQS dead-letter queue). **Idempotency keys make the retries safe.** Add a CloudWatch alarm on the dead-letter queue depth. During the demo, that's your "money is stuck" pager.
- **Connect onboarding:** `POST /wallet/connect` creates an Express account if there isn't one and returns an `accountLinks.create` URL for `SFSafariViewController`. The `account.updated` webhook sets `payoutsEnabled`.

---

## 7. AI layer (`src/ai/`)

| Task | Model / effort | Input | Output (zod) | Latency budget |
|---|---|---|---|---|
| Skill extraction | Opus 5.5, `medium` | PDF document block or CSV text | skills, roles, education, … | ≤ 20s (async, show a spinner) |
| Checklist | Opus 5.5, `low` | title, description, category, photos | `ChecklistItem[]` | ≤ 6s (sync) |
| Re-rank + "why you" | Opus 5.5, `low` | job + 8 candidate twin summaries | ranked list | ≤ 6s |
| Vision grading | Opus 5.5, `medium` | checklist + up to ~10 images | verdicts | ≤ 25s |
| Embeddings | Titan Text Embeddings v2 (1024-d) | twin doc / job text | float[] | < 1s |

Implementation notes:

- **Client:** `AnthropicBedrockMantle` from `@anthropic-ai/bedrock-sdk`, model ID `anthropic.claude-opus-5-5`. Keep the model and effort for each task in `config.ts` so you can step a route down to Sonnet 5.5 if latency hurts.
- **Use structured outputs for everything** (`messages.parse` + `zodOutputFormat`). No regex-parsing JSON out of prose.
- **Thinking can't be disabled on Opus 5.5.** Control latency with `output_config.effort`, which defaults to `medium`, so set it explicitly.
- **Always check `stop_reason === "refusal"`** before reading output. Fallbacks for each task:
  - checklist: a generic template for the category
  - re-rank: the deterministic score order with a templated "why"
  - grading: UNCLEAR, so it goes to the poster
- **Prompt caching:** the system prompts and checklist rubric are static. Put them first and mark them with `cache_control`, which matters for the grading call you'll run many times while rehearsing.
- **Prompt-injection hygiene:** job descriptions, résumés and photos are user content. Put them in clearly delimited blocks and tell the model they are data. Because the grade → money decision is made in code from per-item verdicts, a "mark this as passed" note in a photo can at most flip one item's verdict. It can't skip the code-visible and geo checks.
- **Save every LLM input and output** to S3 under `ai-logs/{task}/{jobId}`. It will help with debugging at 4am, and it's a nice "explainability" moment when a judge asks why something passed.

---

## 8. Push (`src/push/apns.ts`)

- Call APNs directly over HTTP/2 with token auth (ES256 JWT from the `.p8` key, cached for 50 minutes). That's about 60 lines with Node's `http2` and `jose`, with no SNS platform-application setup.
- Headers: `apns-topic: <bundleId>`, `apns-push-type: alert`, `apns-priority: 10`, `apns-expiration: offerExpiresAt`.
- Offer payload:
  ```json
  { "aps": { "alert": { "title": "$15 · 10 min · 0.4 mi", "body": "You're a match: graphic design (LinkedIn)" },
             "category": "JOB_OFFER", "interruption-level": "time-sensitive",
             "relevance-score": 1, "mutable-content": 1, "sound": "default" },
    "offerId": "…", "jobId": "…", "expiresAt": "…" }
  ```
- Development builds use the sandbox host and TestFlight uses production. Store `env` with each device token and route on it. **Mixing these up is the most common reason "push doesn't work."**
- A `410 Unregistered` response deletes the token.
- Use `apns-push-type: liveactivity` for Live Activity countdown updates (stretch).

---

## 9. Escrow contract (`contracts/src/BountyEscrow.sol`)

```solidity
struct Escrow { address poster; address worker; uint128 amount; uint64 deadline; Status status; }
mapping(bytes32 => Escrow) public escrows;           // jobId = keccak256(uuid)
IERC20 public immutable usdc; address public arbiter;

deposit(bytes32 jobId, uint128 amount, uint64 deadline)  // poster; transferFrom; emits Deposited
release(bytes32 jobId, address worker)                    // onlyArbiter; status Funded → Released
refund(bytes32 jobId)                                     // arbiter anytime, OR poster after deadline + grace
```

- Use OpenZeppelin `SafeERC20` and `ReentrancyGuard`, and follow checks → effects → interactions order.
- **Poster self-refund after the deadline** is what backs the pitch line "we can't run off with funds": the arbiter can only send money to a worker or back to the poster, and never to itself.
- Write Foundry tests for: double release, release after refund, refund before the deadline by a non-arbiter, and a wrong amount.
- Keep the arbiter key in Secrets Manager. Fund it with Base Sepolia ETH from a faucet **before** the hackathon.

---

## 10. API surface (v1)

```
POST /auth/linkedin/callback   POST /auth/apple   POST /auth/demo*
GET  /me                       POST /me/devices { token, env }

POST /twin/uploads             POST /twin/ingest           GET  /twin
PATCH/DELETE /twin/skills/:n   PUT  /twin/prefs            PUT  /twin/availability

POST /jobs                     GET  /jobs/:id              GET  /jobs?role=poster|worker
PATCH /jobs/:id/checklist      POST /jobs/:id/fund         POST /jobs/:id/fund/usdc/confirm
POST /jobs/:id/cancel          POST /jobs/:id/start        GET  /jobs/:id/timeline   (ledger)
POST /jobs/:id/proof/uploads   POST /jobs/:id/proof/submit
POST /jobs/:id/approve         POST /jobs/:id/dispute

GET  /offers/current           POST /offers/:id/accept     POST /offers/:id/decline

POST /wallet/connect           GET  /wallet/earnings       PUT  /wallet/address

POST /webhooks/stripe

POST /demo/jobs/:id/fire/:timer*   POST /demo/offer { jobId, userId }*   POST /demo/reset*
                                                                     (* = only when DEMO_MODE)
```

- **Errors:** `{ error: "offer_taken" | "invalid_transition" | …, message }` with 400/401/403/404/409.
- **Real-time updates:** iOS polls `GET /jobs/:id` every 2s on the active-job screen, and pushes cover background updates. Skip WebSockets; they aren't worth the time at a hackathon.

---

## 11. Demo mode and reliability

- `DEMO_MODE=true` shortens durations: offer 30s, review window 2 min, rematch 1 min. It also enables `/demo/*`, which lets you fire any timer immediately, force-offer a job to the judge's phone (skipping the matching lottery), and reset seed data.
- **Before the demo, warm the Lambdas** with a cron ping every 5 minutes, or use provisioned concurrency of 1 on `api`. A cold start plus a Bedrock call is the moment the judge is waiting.
- **Pre-generate** the checklist for the scripted demo job, so the live part is only the push, accept and grade.
- Keep one CloudWatch dashboard: API 5xx, outbox errors, dead-letter queue depth, Bedrock latency p95.

---

## 12. Local development

- `cdk deploy -c stage=<yourname>` gives each person their own tables, bucket and functions, so nobody steps on anyone else's data.
- `npm run dev` runs the Hono app locally against **your stage's real AWS tables** with `INLINE_EFFECTS=true`. Effects run in-process, and the scheduler implementation becomes `setTimeout`.
  - Ledger rows written locally carry `inline: true`, and the deployed outbox skips them, so effects don't run twice.
- Expose the local server with `ngrok`/`cloudflared` for the LinkedIn redirect and the Stripe CLI webhook (`stripe listen --forward-to`).
- **Unit test only `jobMachine.ts`, `money.ts` and the grade decision rule.** Those are where bugs cost money. Everything else gets tested by clicking through the app.

---

## 13. Security checklist (short)

- Every route that changes a job checks that the actor is the poster or the assigned worker. The state-machine guards check it again.
- Presigned URLs are scoped to one key and one content type, and expire in 5 minutes. The bucket is private, and the iOS app reads proof photos through presigned GETs.
- Verify Stripe webhook signatures against the **raw body**. Hono's `c.req.text()` gives you that before any JSON parsing.
- Never trust client-reported payment success. Only the webhook or the on-chain receipt check can move a job to FUNDED.
- Raw résumés can be deleted after extraction. Gmail (stretch) stores only derived skills, never message content.
- App Attest (stretch): `POST /attest/challenge` → attestation on first launch → assertion header on `proof/submit`.

---

## 14. Backend build order (maps to the schedule in the plan)

| Hours | Backend | Payments |
|---|---|---|
| 0–3 | CDK stack with stages, tables + stream, Hono skeleton, `/auth/demo`, `jobMachine.ts` + tests | Stripe test account, Connect Express, Foundry init, arbiter wallet funded |
| 3–10 | LinkedIn OIDC, ingest + skill extraction, checklist generator, embeddings + seed script | PaymentIntent + webhook → FUNDED via `applyEvent` |
| 10–18 | Matching + re-rank, outbox, offer cascade via the scheduler, APNs sender, accept/decline | Contract deploy + tests, `usdc/confirm`, chain poller |
| 18–26 | Proof uploads + submit checks, vision grading + decision rule, review window, deadline refunds | `payout` / `refund` effects for both rails, Connect onboarding link |
| 26–32 | Demo routes, warmers, dashboard, seed polish | Failure drills: webhook replay, double accept, refund after deadline |

**Decide before hour 0:** DynamoDB table names and key shapes (section 4), the `JobEvent`/`Effect` unions (section 5), and the API routes (section 10). Those are the contracts the iOS developers code against. Commit them as `types.ts` plus a shared OpenAPI or Swift `Codable` mirror on day one.
