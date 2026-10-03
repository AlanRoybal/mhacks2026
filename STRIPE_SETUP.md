# Stripe payments for Bounty

> Moved from `backend/` to `payments-server/` when the branches were merged; `backend/` is now the main API (see `docs/API.md`). The app's Debug build now sends checkout to the main backend (port 8787), which serves the same `/payment-sheet` and `GET /jobs/{id}` routes and turns each funded job into a real, matchable job. To use this server instead, set `BOUNTY_PAYMENTS_BASE_URL` to port 4242 in `Config/Local.xcconfig`.

The Post tab now opens Stripe's native PaymentSheet to fund a job. The backend computes the 10% platform fee, creates one PaymentIntent per checkout, and saves jobs in SQLite. Confirmed funding changes the job to `funded` and appends one `JOB_FUNDED` record to `LedgerEvents` in the same transaction. A job appears under Jobs → Posted only after the backend verifies the full payment succeeded. Pending payment IDs are saved on the phone so an interrupted confirmation can recover when the app reopens or returns to the foreground.

For a **$15 job**, the existing 10% fee is **$1.50**, so PaymentSheet collects **$16.50 USD**. Funding captures the poster's test payment; worker transfers happen in a later stage.

This is a local, test-mode integration. It charges the requester; Connect onboarding, worker transfers, refunds, and live payments are separate work. The app and backend reject live Stripe keys. No API secret is compiled into the iOS app.

## Run the backend

Use Node 22.13 or newer. Dependencies and a temporary Stripe sandbox have been set up locally. Its keys are in the ignored `payments-server/.env`; keep this file private. The current sandbox expires **October 10, 2026** unless claimed.

```sh
cd payments-server
npm ci
npm start
```

The default address is `http://127.0.0.1:4242`. The iOS Debug configuration points at the main backend (port 8787); set `BOUNTY_PAYMENTS_BASE_URL` to this address in `Config/Local.xcconfig` to use this server. Open `Bounty.xcodeproj` and run the Bounty scheme. Swift Package Manager resolves the pinned StripePaymentSheet 26.12.1 package. `project.yml` contains the same dependency for XcodeGen users.

To replace the sandbox with an existing Stripe test account, copy `.env.example` to `.env` and set matching secret and publishable keys from that account. For a fresh anonymous sandbox:

```sh
npx stripe --config .stripe/config.toml sandbox create --from-git --non-interactive
```

Copy the resulting test keys to `.env`. Claim the current sandbox before it expires:

```sh
npx stripe --config .stripe/config.toml sandbox claim
```

## Forward webhooks

In a second terminal in `payments-server`:

```sh
npm run webhooks
```

Set `STRIPE_WEBHOOK_SECRET` in `.env` to the listener's `whsec_...` signing secret, then restart the backend. This has already been configured for the current local listener. The raw-body webhook handler validates signatures and tolerates duplicate, unrelated, and out-of-order payment events. The app also asks Stripe for the payment status through the server, so it can confirm funding without waiting for a webhook.

## Test a payment

1. In the app, complete onboarding and open Post.
2. Enter a title, description, future deadline, and job pay between $0.50 and $10,000 (whole cents).
3. Tap **Review & fund job** and review job pay, the 10% platform fee, and total.
4. Open PaymentSheet and use `4242 4242 4242 4242`, any future expiry, and any three-digit CVC.
5. Wait for **Job funded**, then look in Jobs → Posted.

Use `4000 0000 0000 0002` to check declines, and `4000 0025 0000 3155` for authentication. Canceling or failing payment does not publish a job. Retrying the same checkout reuses its PaymentIntent.

```sh
npm test
npm run test:sandbox
npm run test:webhook
```

The unit/integration suite covers authoritative amounts, validation, retries, persistence, append-only ledger records, atomic rollback, payment state, and signed webhooks. `test:sandbox` requires the running backend and creates a $16.50 test charge for a $15 job, checking a canceled checkout and a declined card before confirming a Visa test card. It never uses a live key.

`test:webhook` also requires `npm run webhooks` to be running with its signing secret in the backend's `.env`. It creates another test payment and checks SQLite directly **before** calling the job-status endpoint after success. It checks both `funded` and exactly one `LedgerEvents` entry with the matching PaymentIntent and Stripe event ID and `source: 'webhook'`. This proves the Stripe webhook performs funding; the status endpoint's reconciliation cannot make this check pass. Running `stripe trigger payment_intent.succeeded` alone will not fund an existing job because the generated fixture is not that job's PaymentIntent.

## Follow a payment through the code

1. `CreateJobView.swift` creates a `FundingDraft` with a stable job UUID and an amount in cents, then opens `PaymentCheckoutView`.
2. `PaymentAPI.prepare` sends the draft to `POST /payment-sheet`. In `payments-server/payments.mjs`, the server saves a `draft` job, calculates the 10% fee, and creates a PaymentIntent with `metadata.job_id`, the total, and an idempotency key derived from the job UUID. For a $25 job, the charge is $27.50. Retries reuse this PaymentIntent.
3. The server returns the client secret and publishable key. `PaymentAPI.prepare` builds Stripe's native PaymentSheet. Apple Pay, when configured below, confirms the same PaymentIntent as card entry.
4. Stripe sends `payment_intent.succeeded` to `POST /stripe/webhook`. In `payments-server/app.mjs`, `express.raw` preserves the original request bytes and `stripe.webhooks.constructEvent` verifies the signature.
5. `Payments.applyIntent` matches the job and PaymentIntent, checks test mode, currency, expected total, and amount received, then atomically appends `JOB_FUNDED` to `LedgerEvents` and saves `status: 'funded'` in SQLite. The ledger includes the job, PaymentIntent, Stripe event ID, amounts, and timestamp. Unique constraints prevent duplicate funding records, and SQLite rejects updates or deletes to the ledger. Older failure/cancellation events and overlapping checkout retries cannot undo funding or rewind a later job state.
6. After PaymentSheet completes, the app fetches `GET /jobs/:id` and adds the job to Jobs → Posted only when the server reports `funded`. The endpoint can also reconcile directly with Stripe if delivery is delayed. Pending job IDs survive app restarts.

The build-plan state **FUNDED** is represented as lowercase `funded` in the API and `.funded` in Swift. PaymentSheet's completion callback alone does not publish a job.

## Run on an iPhone

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `BOUNTY_PAYMENTS_BASE_URL` to your Mac's LAN address or an HTTPS backend. For LAN testing, set `HOST=0.0.0.0` in `payments-server/.env`, restart it, and connect both devices to the same network. The local override is ignored by Git. Release builds require an HTTPS URL.

## Enable Apple Pay

PaymentSheet's Apple Pay configuration code already exists in `PaymentCheckoutView.swift`. Native Apple Pay requires an Apple Developer Program membership and a merchant ID owned by the same team that signs the app. The project currently uses team `DVX8YZ9GG9` and bundle ID `com.alanroybal.BountyTwin`; use the team's existing merchant ID or register one for this app.

1. In [Apple Developer → Identifiers](https://developer.apple.com/account/resources/identifiers/add/merchant), register a **Merchant ID**. A suggested identifier is `merchant.com.alanroybal.BountyTwin`; use the exact registered value in every following step.
2. In the **same Stripe account/sandbox used by `payments-server/.env`**, open [iOS Certificate Settings](https://dashboard.stripe.com/settings/ios_certificates), choose **Add new application**, and download Stripe's certificate signing request (CSR).
3. Open your Merchant ID in Apple Developer. Create an **Apple Pay Payment Processing Certificate**, uploading the CSR downloaded from Stripe. Download Apple's resulting certificate and upload it back into the Stripe setup flow. Each Stripe CSR is for one certificate. This is the payment-processing certificate, not an Apple Pay Merchant Identity certificate.
4. The project supplies `Config/ApplePay.entitlements`, which includes Apple Pay and the existing push-notification entitlements. Selecting it in the next step lets Xcode's automatic signing provision the matching merchant ID. If needed, open **Bounty project → Bounty target → Signing & Capabilities → Apple Pay** and select your registered Merchant ID. The default entitlement file remains usable before merchant setup is complete.
5. Create `Config/Local.xcconfig` if needed. For the Simulator, use:

   ```xcconfig
   BOUNTY_PAYMENTS_BASE_URL = http:/$()/127.0.0.1:4242
   BOUNTY_APPLE_PAY_MERCHANT_IDENTIFIER = merchant.com.alanroybal.BountyTwin
   BOUNTY_CODE_SIGN_ENTITLEMENTS = Config/ApplePay.entitlements
   ```

   Replace the example merchant ID with your registered value. For an iPhone, use the Mac's LAN IP instead of `127.0.0.1`, set backend `HOST=0.0.0.0`, restart the backend, and use the same Wi-Fi network. Do not copy the example LAN IP without changing it.
6. Rebuild and run the app. Open Post, review the payment, then open PaymentSheet. On a supported iPhone with a card in Wallet, Apple Pay should appear alongside card entry. Confirm payment and check **Job funded** and Jobs → Posted.

With Stripe test keys, use a real card already added to Wallet for an Apple Pay test; Stripe creates a test payment without charging that card. The `4242` test number is for card entry in PaymentSheet and cannot be added to Wallet. See [Stripe's Apple Pay testing instructions](https://docs.stripe.com/apple-pay?platform=ios#test-apple-pay).

If Apple Pay does not appear, check the registered Merchant ID, Xcode entitlement and signing team, Stripe certificate, `Config/Local.xcconfig`, and Wallet availability. Card-entry checkout remains usable while Apple Pay is being configured. See [Stripe's PaymentSheet Apple Pay guide](https://docs.stripe.com/payments/accept-a-payment?payment-ui=mobile&platform=ios#optional-enable-apple-pay).

## Before production

This payments server has no account authentication and is intended for local sandbox testing. Before public deployment, integrate authenticated job ownership with the application's backend, move the ledger to its database, and implement the planned Stripe Connect onboarding and separate transfers. Funding currently captures the charge into the platform's Stripe balance; it does not transfer money to a worker or provide an escrow service. Add refund handling and the job review/release state machine before taking real payments.

References: [Stripe iOS integration](https://docs.stripe.com/payments/accept-a-payment?payment-ui=mobile&platform=ios), [PaymentIntent creation](https://docs.stripe.com/api/payment_intents/create), [webhook verification](https://docs.stripe.com/webhooks), [temporary sandboxes](https://docs.stripe.com/cli/sandbox).
