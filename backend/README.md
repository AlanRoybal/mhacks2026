# Bounty Twin backend

TypeScript on Node 22+. One HTTP API (Hono) and one worker, which run on a laptop with no accounts at all and deploy to AWS with one command.

- [docs/API.md](../docs/API.md): the API the iOS app calls.
- [docs/BACKEND.md](../docs/BACKEND.md): the design and why it is built this way.

## Run it locally

```bash
cd backend
npm install
npm run dev
```

That serves `http://localhost:8787` with:
- an in-memory store, saved to `.data/` so restarts keep your data
- in-process timers and effects
- offline AI (`AI_PROVIDER=fake`)
- console push
- instant fake payments

Delete `.data/` to start over.

Seed it with Ann Arbor jobs and a demo worker:

```bash
npm run seed
```

To try it from a phone on the same Wi-Fi, set `PUBLIC_BASE_URL=http://<your-laptop-ip>:8787` (upload and file links use it), or tunnel with ngrok or cloudflared.

Turn on real services one at a time in `.env` (copy `.env.example`):

| Want | Set |
|---|---|
| Real Claude | `AI_PROVIDER=anthropic` and `ANTHROPIC_API_KEY`, or `AI_PROVIDER=bedrock` with AWS credentials |
| Real pushes | `PUSH_PROVIDER=apns`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8` |
| Stripe test mode | `PAYMENTS_PROVIDER=stripe`, both keys, and `stripe listen --forward-to localhost:8787/webhooks/stripe` for `STRIPE_WEBHOOK_SECRET` |
| LinkedIn sign-in | `LINKEDIN_CLIENT_ID` and `LINKEDIN_CLIENT_SECRET`. Register `<PUBLIC_BASE_URL>/auth/linkedin/callback` as a redirect URL. |
| Short demo timers | `DEMO_MODE=true` (30-second offers, 2-minute review window, `/demo/*` routes) |

## Test

```bash
npm run typecheck
npm test
```

About 130 tests run in a few seconds with no network. They cover:
- the state machine, including a 10,000-run randomized test that money moves at most once per job
- the store
- every API flow: posting, matching, offers, proof, grading, payments, review, disputes and the sweeper
- push payloads
- AI fallbacks

## Deploy

```bash
cd backend
cp .env.example .env   # set JWT_SECRET, DEMO_MODE, AI and payment keys
npx cdk bootstrap      # once per AWS account and region
npx cdk deploy -c stage=dev
```

Each stage name gets its own stack, so teammates can deploy `-c stage=alan` and `-c stage=vedansh` side by side. The outputs include:
- `ApiUrl`: give it to the app.
- `StripeWebhookUrl`: add it in the Stripe dashboard.
- `LinkedInRedirectUrl`: add it to the LinkedIn app.

Watch the `EffectsDlqAlarm`. A message in that queue means a payout, refund, push, timer or grade failed every retry.

The stack has not been deployed yet. [infra/README.md](infra/README.md) has handoff notes for whoever owns AWS: every setting, and what is still open.

## How it fits together

```
iOS app ──HTTPS──▶ api Lambda (src/handlers/api.ts → src/api/app.ts, all routes)
                        │ applyEvent(): read job → transition() → write job + ledger row (version-checked)
                        ▼
                  DynamoDB ledger table ──stream──▶ worker Lambda (src/handlers/worker.ts)
                                                      runs the row's effects: match, offer, push,
                                                      schedule timer, grade, payout, refund, stats
                  EventBridge Scheduler (timers) ─────▶ worker → fireTimer() → applyEvent()
                  EventBridge rule (every minute) ────▶ worker → sweep() (backstop for anything lost)
```

Locally, the same code runs in one process. `EFFECTS_MODE=inline` runs effects right after each commit, and `SCHEDULER=local` uses `setTimeout` timers saved to `.data/timers.json`.

### The rule that keeps money safe

Every job change goes through `applyEvent` (`src/services/jobs.ts`):
1. It reads the job.
2. It asks the pure state machine `transition()` (`src/domain/jobMachine.ts`) whether the event is allowed.
3. It writes the new job and an append-only ledger row in one transaction, conditional on the version it read.

If two requests race, as when two workers tap Accept, one commit wins and the other re-reads and is refused.

Money only moves through the `payout` and `refund` effects that `transition()` emits. They are idempotent, so retries are safe. Timers and the sweeper only propose events, and a stale proposal is rejected.

## Where things live

| Path | What |
|---|---|
| `src/domain/` | Pure logic. `jobMachine.ts` (every rule about job state), `types.ts` (records), `events.ts` (events and effects), `rules.ts` (timings and demo values), `money.ts`, `availability.ts`, `geo.ts`, `ids.ts`. |
| `src/services/` | Use cases. `jobs.ts` (`applyEvent`), `effects.ts` (effect runner), `postings.ts` (drafts and checklists), `matching.ts`, `proof.ts`, `grading.ts`, `payments.ts`, `twin.ts`, `users.ts`, `timers.ts`, `sweeper.ts`, `notify.ts`. |
| `src/api/` | HTTP. `app.ts` (routing), `auth.ts`, `wire.ts` (the JSON shapes the app decodes), `routes/*`. |
| `src/ai/` | Claude calls (`claude.ts`), prompts, the offline fallback (`fake.ts`), outage fallbacks (`resilient.ts`), embeddings. |
| `src/payments/` | The `PaymentRail` interface, Stripe, fake, and a USDC placeholder. |
| `src/push/`, `src/scheduler/`, `src/blobs/`, `src/store/` | Adapters, each with a local version and an AWS version. |
| `src/handlers/` | Lambda entry points. `src/local.ts` is the laptop server. |
| `infra/` | CDK stack. |
| `scripts/seed.ts` | Seeds any running stage through the API. |

### Adding a feature

- **A new kind of job change:**
  1. Add the event to `JobEvent` (`events.ts`).
  2. Add a `case` in `transition()` with its guards and tests.
  3. Call it through `applyEvent` from a route or effect.
- **A new side effect:**
  1. Add it to `Effect`.
  2. Handle it in `services/effects.ts`. It must be safe to run twice; otherwise add its kind to `AT_MOST_ONCE`.
- **A new field for the app:**
  1. Add it in `src/api/wire.ts`.
  2. Note it in `docs/API.md`. Swift ignores unknown keys, but it fails on unknown enum values and on missing non-optional fields.
