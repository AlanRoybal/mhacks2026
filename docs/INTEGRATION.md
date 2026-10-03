# How the branches fit together

The `integration` branch merges the team's work into one app and one backend:
- `main` (including iosA's redesign and the TwinKit package)
- the Figma design handoff
- `payment` (Caleb's Stripe checkout)
- `backend`

`iOS-B` is not merged: its screens overlap iosA's. Its `Job.swift` JSON is still what the backend's job routes return, so iosA can adopt those models later.

## What came from where

| Area | Source | Notes |
|---|---|---|
| App screens, navigation, design system | iosA (`main`) | The base for every UI conflict. |
| `Packages/TwinKit` (sign-in, twin profile, offers) | iosA | The backend serves its routes unchanged ([API.md](API.md#twinkit-routes)). |
| Stripe checkout (`PaymentCheckoutView`, `PostedJobsStore`, Apple Pay entitlements) | `payment` | Wired into iosA's three-step post flow (Post a job → What counts as done → Fund) through `PostDraft`, which all three screens share. USDC is still simulated. |
| Main API (`backend/`) | `backend` | Jobs, matching, offers, proof, grading, payouts. It also serves the checkout's `/payment-sheet` and `GET /jobs/{id}`. |
| Caleb's Stripe sandbox server | `payment` | Moved from `backend/` to `payments-server/`, with no code changes. It still works on its own. |

Merge decisions:
- **Checkout target.** The Debug build sends checkout to the main backend (port 8787), so a funded job becomes a real job that gets matched. To use Caleb's server instead, point `BOUNTY_PAYMENTS_BASE_URL` at port 4242.
- **Job card.** iosA's `Job` model gained a `funded` status, shown with the grey "pending" chip.
- **Project file.** `PostDraft.swift` uses object IDs starting `BD…`, so they don't collide with the `A1…` IDs the payment branch adds.

## Run it

1. **Backend:**
   ```bash
   cd backend
   npm install
   npm run dev
   ```
   This serves `http://localhost:8787` with fake payments, offline AI and console pushes, so it needs no accounts. `npm run seed` adds demo jobs and a worker. See [backend/README.md](../backend/README.md) for real Claude, Stripe, APNs and LinkedIn.
2. **App, in the Simulator:** open `Bounty.xcodeproj` and run the Bounty scheme. Checkout already points at `127.0.0.1:8787`.
3. **App, on an iPhone:** copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and set both URLs to your Mac's LAN IP. Then set `PUBLIC_BASE_URL=http://<lan-ip>:8787` in `backend/.env`.
4. **Data source:** `BOUNTY_API_BASE_URL` is empty by default, which keeps the home, jobs and twin screens on sample data. Set it once those screens call TwinKit.

With fake payments, Fund shows "Job funded" right away. With `PAYMENTS_PROVIDER=stripe` and test keys in `backend/.env`, it opens Stripe's PaymentSheet (card `4242 4242 4242 4242`).

## Verified

- **Backend:** typecheck and the full test suite, including the TwinKit and checkout contract tests.
- **iOS build:** `xcodebuild` for the Simulator succeeds against a local stub of `StripePaymentSheet`. The real package (stripe-ios-spm 26.12.1) wasn't downloaded for this check.
- **End to end:** in the Simulator against `npm run dev`, Post → checklist → Fund → "Job funded". The backend logged the job going DRAFT → FUNDED and starting matching.
- **Not run:** `payments-server/` tests. Its dependencies weren't installed, and its code is identical to the `payment` branch.

## Gaps between the app and the backend

1. **Push tokens are never registered.** TwinKit has no call for `POST /me/devices`, so workers can't receive offers. Add it after `registerForRemoteNotifications`.
2. **The checkout sends no session.** That's fine locally, where jobs go to a guest poster. Deployed stages need `Authorization: Bearer <token>` from TwinKit's `SessionStore` on `PaymentAPI` requests.
3. **No location for in-person jobs.** `FundingDraft` sends no coordinates, so the backend places in-person jobs at a campus default. Add `location { latitude, longitude, address }`, geocoded from the Post screen's address.
4. **Offer accept/decline from a push.** `PushNotificationManager` should read `offerId` and call `OfferService.respond`. TwinKit's `JobOffer` DTO has no fetch endpoint; use `GET /offers/{id}`.
5. **LinkedIn redirect.** TwinKit uses the custom-scheme redirect `bounty://oauth/linkedin`. If LinkedIn rejects custom schemes, use the server flow `/auth/linkedin/start`.
6. **Sample-data screens.** Jobs, proof capture and review still use sample data. [API.md](API.md) has the routes, and `allowedActions` on each job says which buttons to show.
7. **Categories don't line up.** The Post screen's categories (Yard work, Errands, …) map onto the checkout's five (Design, Home, Tutoring, Photography, Technology). Yard work and Errands both become Home, for example.

AWS is owned by someone else. [backend/infra/README.md](../backend/infra/README.md) has the deploy notes and what is still open.
