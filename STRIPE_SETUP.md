# Stripe payments for Bounty

The Post tab now opens Stripe's native PaymentSheet to fund a job. The backend computes the 10% platform fee, creates one PaymentIntent per checkout, and saves jobs in SQLite. A job appears under Jobs → Posted only after the backend verifies the full payment succeeded. Pending payment IDs are saved on the phone so an interrupted confirmation can recover when the app reopens.

This is a local, test-mode integration. It charges the requester; Connect onboarding, worker transfers, refunds, and live payments are separate work. The app and backend reject live Stripe keys. No API secret is compiled into the iOS app.

## Run the backend

Use Node 22.13 or newer. Dependencies and a temporary Stripe sandbox have been set up locally. Its keys are in the ignored `backend/.env`; keep this file private. The current sandbox expires **October 10, 2026** unless claimed.

```sh
cd backend
npm ci
npm start
```

The default address is `http://127.0.0.1:4242`. The iOS Debug configuration already points there for the Simulator. Open `Bounty.xcodeproj` and run the Bounty scheme. Swift Package Manager resolves the pinned StripePaymentSheet 26.12.1 package. `project.yml` contains the same dependency for XcodeGen users.

To replace the sandbox with an existing Stripe test account, copy `.env.example` to `.env` and set matching secret and publishable keys from that account. For a fresh anonymous sandbox:

```sh
npx stripe --config .stripe/config.toml sandbox create --from-git --non-interactive
```

Copy the resulting test keys to `.env`. Claim the current sandbox before it expires:

```sh
npx stripe --config .stripe/config.toml sandbox claim
```

## Forward webhooks

In a second terminal in `backend`:

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
```

The unit/integration suite covers authoritative amounts, validation, retries, persistence, payment state, and signed webhooks. `test:sandbox` requires the running backend and creates a $27.50 test charge, first checking a declined card and then confirming a Visa test card. It never uses a live key.

## Run on an iPhone

Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set `BOUNTY_PAYMENTS_BASE_URL` to your Mac's LAN address or an HTTPS backend. For LAN testing, set `HOST=0.0.0.0` in the backend's `.env`, restart it, and connect both devices to the same network. The local override is ignored by Git. Release builds require an HTTPS URL.

## Apple Pay and production

Card payments work without Apple Pay. To enable Apple Pay, create an Apple merchant ID, configure its Stripe payment-processing certificate, add the matching Apple Pay capability to Bounty (including its entitlement in `Bounty/Bounty.entitlements`), and set `BOUNTY_APPLE_PAY_MERCHANT_IDENTIFIER` in `Config/Local.xcconfig`. PaymentSheet enables Apple Pay only when this is configured. See [Stripe's iOS payment guide](https://docs.stripe.com/payments/accept-a-payment?payment-ui=mobile&platform=ios).

This backend has no account authentication and is intended for local sandbox testing. Before public deployment, integrate authenticated job ownership with the application's backend, move the ledger to its database, and implement the planned Stripe Connect onboarding and separate transfers. Funding currently captures the charge into the platform's Stripe balance; it does not transfer money to a worker or provide an escrow service. Add refund handling and the job review/release state machine before taking real payments.

References: [Stripe iOS integration](https://docs.stripe.com/payments/accept-a-payment?payment-ui=mobile&platform=ios), [PaymentIntent creation](https://docs.stripe.com/api/payment_intents/create), [webhook verification](https://docs.stripe.com/webhooks), [temporary sandboxes](https://docs.stripe.com/cli/sandbox).
