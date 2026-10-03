# How the branches fit together

The `integration` branch merges the team's work into one app and one backend:
- `main` (including iosA's redesign and the TwinKit package)
- the Figma design handoff
- `payment` (Caleb's Stripe checkout)
- `backend`

`iOS-B` (Vishnu, poster side) is merged additively on top of this integration; see [Poster screens from iOS-B](#poster-screens-from-ios-b).

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

## Poster screens from iOS-B

Added on top of the integration without changing iosA's screens, `PostDraft` or the checkout:

- **Jobs › Posted** lists the poster's real jobs from `GET /jobs/mine`, polling while open. `BackendJobsAPI` signs in as the demo handle `guest-poster`, the account checkout files jobs under when it sends no session, so funded jobs appear here.
- **A posted job** opens its status timeline (route `postedJob`). One in review opens the live **Review proof**, with per-item AI grades, approve (`POST /jobs/{id}/approve`) and dispute (`POST /jobs/{id}/dispute`, which must name a checklist item). With no job selected, Review proof shows iosA's sample.
- **Post a job:** the address field has a locate button (search or current location). The picked coordinates go to `/payment-sheet` as the optional `location`.
- **No backend running:** `PosterStore` switches to `MockJobsAPI` sample jobs and says so under the Posted list.
- **Poster alerts:** the app registers its APNs token with `POST /me/devices` (as `guest-poster`) at launch. Tapping a poster push (`proof_ready`, `proof_needs_decision`, `offer_accepted`, …) opens that job: the review when it's waiting on the poster, else its timeline. A local "Review closing soon" reminder fires before payment auto-releases (30 s ahead in 2-minute windows, an hour ahead otherwise). `PosterPush.swift` has the type lists.
- **Models:** the backend-shaped model is `PostedJob` (`Bounty/Models/PostedJob.swift`); `Job` stays iosA's display model for the worker screens.

Verified on the iPhone 17 simulator (build, Posted list, review, approve, locate) and against `npm run dev` with curl (checkout with location, `/jobs/mine`, dispute, approve).

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

1. **Push tokens for workers.** The app now registers its token, but as the poster (`guest-poster`), so poster alerts arrive. Workers still can't receive offers until the worker side signs in with TwinKit and registers under that account.
2. **The checkout sends no session.** That's fine locally, where jobs go to a guest poster. Deployed stages need `Authorization: Bearer <token>` from TwinKit's `SessionStore` on `PaymentAPI` requests.
3. **Location for in-person jobs.** Fixed when the poster uses the address field's locate button. A typed address with no pick still has no coordinates, so the backend uses its campus default; geocoding typed addresses would close this.
4. **Offer accept/decline from a push.** `PushNotificationManager` should read `offerId` and call `OfferService.respond`. TwinKit's `JobOffer` DTO has no fetch endpoint; use `GET /offers/{id}`.
5. **LinkedIn redirect.** TwinKit uses the custom-scheme redirect `bounty://oauth/linkedin`. If LinkedIn rejects custom schemes, use the server flow `/auth/linkedin/start`.
6. **Sample-data screens.** The poster side (Posted list, posted job, review) now uses real data. Worker jobs, proof capture and the "What counts as done" step still use sample data; that step shows the lawn checklist for every job, because checkout creates the job (and its AI checklist) only at funding. [API.md](API.md) has the routes, and `allowedActions` on each job says which buttons to show.
7. **Categories don't line up.** The Post screen's categories (Yard work, Errands, …) map onto the checkout's five (Design, Home, Tutoring, Photography, Technology). Yard work and Errands both become Home, for example.

AWS is owned by someone else. [backend/infra/README.md](../backend/infra/README.md) has the deploy notes and what is still open.
