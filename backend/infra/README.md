# AWS deployment: handoff notes

This CDK app is a starting point for whoever owns AWS. `npm run synth` builds it cleanly, but it has never been deployed. Below is what it creates, what it needs, and what is still open.

## What one stack creates

Each stage gets its own stack (`npx cdk deploy -c stage=<name>`), so several people can deploy side by side.

| Resource | Purpose |
|---|---|
| HTTP API → `api` Lambda | Every route (`src/handlers/api.ts`). Node 22, arm64, ESM, 29 s timeout. |
| `worker` Lambda | Runs effects from the ledger stream, EventBridge Scheduler timers, the one-minute sweep, and background tasks (résumé import, matching, grading). 5 min timeout. |
| DynamoDB tables (on demand) | `jobs` (indexes `byPoster`, `byWorker`), `users`, `offers` (indexes `byJob`, `byWorker`), `proofs`, `ledger` (stream), `kv` (TTL). |
| S3 bucket | Uploads. Private; the API hands out presigned PUT and GET URLs. |
| Scheduler group and role | One-shot timers that invoke the worker and delete themselves. |
| SQS dead-letter queue and alarm | Ledger effects that failed every retry. |
| EventBridge rule | Runs the sweep every minute. It is the backstop for lost timers, stalled matching, stuck grading, payouts and refunds. |

The stack outputs `ApiUrl`, `StripeWebhookUrl`, `LinkedInRedirectUrl` and `EffectsDlqUrl`.

## Deploy

```bash
cd backend
cp .env.example .env    # fill in the settings below
npx cdk bootstrap       # once per account and region
npx cdk deploy -c stage=dev
```

`infra/app.ts` reads `backend/.env` and copies the settings listed in `PASSTHROUGH` (in `stack.ts`) into both Lambdas' environment. `PUBLIC_BASE_URL` is not among them, since it is the laptop's address; the stack uses the API's own URL instead.

| Setting | Needed for |
|---|---|
| `JWT_SECRET` | **Required.** Generate it with `openssl rand -hex 32`. Without it the Lambdas fail at startup and every request returns 500. The stack doesn't check for it. |
| `DEMO_MODE=true`, `DEMO_LOGIN_KEY` | Short timers and `/demo/*` routes for judging. On a deployed stage, demo sign-in needs the header `x-demo-key`. |
| `AI_PROVIDER=anthropic`, `ANTHROPIC_API_KEY` | Real Claude. This is the simplest path because it needs no IAM. Without it the stage uses the offline heuristics. |
| `PAYMENTS_PROVIDER=stripe`, `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_WEBHOOK_SECRET` | Real test-mode payments. The app accepts only `pk_test_` keys. Add `StripeWebhookUrl` in the Stripe dashboard with the events `payment_intent.succeeded` and `account.updated`, and take the webhook secret from that endpoint. |
| `PUSH_PROVIDER=apns`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8` | Real pushes. `APPLE_BUNDLE_ID` defaults to the app's ID, `com.alanroybal.BountyTwin`. Each device registers as sandbox or production, and the server picks the matching APNs host. |
| `LINKEDIN_CLIENT_ID`, `LINKEDIN_CLIENT_SECRET` | LinkedIn sign-in. Register `LinkedInRedirectUrl` for the server flow and `bounty://oauth/linkedin` for TwinKit's PKCE flow. |
| `ADMIN_USER_IDS` | Comma-separated user IDs that may resolve disputes. |

After the deploy:
1. Smoke-test it: `BASE_URL=<ApiUrl> DEMO_LOGIN_KEY=<key> npm run seed`.
2. Point the app at it. In `Config/Local.xcconfig`, set `BOUNTY_API_BASE_URL` and `BOUNTY_PAYMENTS_BASE_URL` to `ApiUrl`, written as `https:/$()/...`.

## Still open

1. **Secrets** are plain Lambda environment variables. That is fine for the hackathon; move them to Secrets Manager or SSM before real users.
2. **Bedrock is unverified.**
   - `AI_PROVIDER=bedrock` calls Claude through the Bedrock Mantle endpoint (`AnthropicBedrockMantle` in `src/ai/index.ts`).
   - The roles grant `bedrock:InvokeModel`, `bedrock:InvokeModelWithResponseStream` and `bedrock-mantle:*` on `*`. I couldn't confirm which IAM actions Mantle actually checks, so verify them, then narrow the resources.
   - Enable model access for the Claude model, and for Titan Text Embeddings v2 if you set `EMBED_PROVIDER=titan`.
   - Server-side model fallbacks are only requested on the Claude API path.
3. **Nobody is notified by the DLQ alarm.** `EffectsDlqAlarm` has no action. Add an SNS topic or email; a message in that queue can mean a stuck payout or refund.
4. **No custom domain.** URLs use the `execute-api` address. If you add a domain:
   - change `PUBLIC_BASE_URL` in `stack.ts`
   - re-register the Stripe webhook and the LinkedIn redirect
5. **Removal policy.** Any stage other than `prod` deletes its tables and bucket on `cdk destroy`. `prod` keeps them and turns on point-in-time recovery.
6. **The stream starts at `LATEST`.** Ledger rows written before the worker's event source exists are not replayed. The sweep recovers timers, stalled matching, grading, payouts and refunds, but a lost push is not resent.
7. **`payments-server/` is not deployed.** That is Caleb's standalone Stripe sandbox server. The main API serves the same checkout routes (`POST /payment-sheet`, `GET /jobs/{uuid}`), so the app only needs `ApiUrl`.
