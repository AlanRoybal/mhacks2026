# Bounty Twin — Build Plan (working name)

A native Swift iOS app with three parts. People post jobs with money attached. Each worker has an AI "digital twin" that knows their skills and searches the jobs for them. Matched jobs arrive as push notifications the worker can accept or decline, Uber-style. The platform holds the payment in escrow until there is proof the job was done.

> **Tags used below:** **[MVP]** = build at MHacks. **[Stretch]** = only if there's time. **[Product]** = after the hackathon. 💡 marks a suggestion.

---

## 1. Platform facts that shape the design

| Area | What's true today | What we do about it |
|---|---|---|
| LinkedIn login | "Sign In with LinkedIn using OpenID Connect" only returns name, email, photo and a member ID. Work history and skills need LinkedIn partner programs, which we won't get approved at a hackathon. | Use LinkedIn sign-in for identity. Get skills from **(a)** the LinkedIn data export ZIP (it has `Skills.csv`, `Positions.csv`, `Education.csv`) or the profile's "Save to PDF" file, and **(b)** a résumé PDF. Both are parsed by an LLM. |
| Email (Gmail) | `gmail.readonly` is a *restricted* scope. In a public app it requires Google's verification plus a security audit. An unverified app in "Testing" mode works for up to 100 test users, which is fine for MHacks. | Run the Google project in Testing mode and add teammates and judges as test users. Only read **sent mail metadata and subjects from the last 12 months**, summarize skills on the server, and never store raw email. 💡 Make Microsoft Graph `Mail.Read` the Outlook/school-account option. |
| Calendar | iOS EventKit (`requestFullAccessToEvents`, iOS 17+) can read events on the device. It also covers Google calendars the user has already added to iOS. | Calendar data stays **on the device**. The app uploads only free/busy blocks so matching can tell when the worker is available. Adding Google Calendar API access later is optional. |
| Push | APNs supports *actionable notifications* (a `UNNotificationCategory` with actions). Each action can have `.authenticationRequired`, and the notification can use the `timeSensitive` interruption level. | Put **Accept / Decline** directly on the notification. Accept requires Face ID. The Notification Content Extension shows a rich offer card. |
| Payments in an iOS app | Payments for real-world services done outside the app (for example lawn mowing or physical art) can use Stripe instead of Apple's in-app purchase (App Review Guideline 3.1.3(e)/3.1.5). | Use Stripe with Apple Pay through the PaymentSheet. Workers get paid through Stripe Connect. |
| Escrow with Stripe | Stripe Connect "separate charges and transfers" lets the platform charge the poster, hold the money in the platform balance, and send it to the worker's connected account later. A card *authorization hold* lasts only about 7 days, so we don't rely on it. | Charge the poster when they post the job. Send the money to the worker when the job is approved. Refund the poster if the job expires. |
| Crypto | Apple has stricter review rules for crypto apps (Guideline 3.1.5(b)). The easiest legal setup for a hackathon is the user's own wallet working with a smart contract we deploy, on a **testnet**. | USDC escrow contract on **Base Sepolia** (testnet), with wallet connection through the Reown (WalletConnect) AppKit Swift SDK or Coinbase Wallet SDK. 💡 Stripe has also offered stablecoin (USDC) acceptance. Check whether our account has it, because that would let us skip writing a contract. |
| Legal | Holding user money can make a company a money transmitter. Stripe Connect handles that compliance for card payments. Crypto escrow through a smart contract the platform doesn't hold keys to avoids most of it. | In the pitch, say "Stripe Connect plus a smart contract we don't control the funds of." Don't claim we hold anyone's funds ourselves. |

---

## 2. Feature list

### A. Onboarding and building the digital twin
1. **[MVP]** Sign in with LinkedIn (OpenID Connect). 💡 Add Sign in with Apple as a fallback, because App Review requires it when other social logins are offered.
2. **[MVP]** Upload a résumé or LinkedIn PDF/ZIP. An LLM extracts skills, roles, education, years of experience and certifications.
3. **[MVP]** Connect Calendar (EventKit). It infers weekly availability, such as "free Sat mornings, weekday evenings."
4. **[Stretch]** Connect Gmail/Outlook. It infers informal skills and proven work, like "has invoiced clients for logo design" or "tutors calculus."
5. **[MVP]** **Twin profile screen**: skills with a confidence score and the source each one came from ("from LinkedIn," "from email"). The user can edit, delete or add skills. 💡 This screen is how users come to trust the twin, so make it look good.
6. **[MVP]** Preferences: minimum pay, maximum travel radius, job categories to always reject, remote vs. in-person, and quiet hours.
7. **[Stretch]** "Chat with your twin": ask it why it picked or skipped a job, and it learns from corrections.

### B. Posting jobs (requester side)
8. **[MVP]** Create a job: title, description, photos, category, location (or remote), deadline, and payment amount in USD or USDC.
9. **[MVP]** **AI proof-of-work spec**: when the job is posted, an LLM turns the description into an objective acceptance checklist plus the evidence required (for example, a lawn job needs before and after photos from 4 angles plus an on-site location check-in). The poster can edit it before funding. 💡 This is our answer to "how do you verify the job was done": both sides agree on what counts as proof *before* any money moves.
10. **[MVP]** Fund escrow (Stripe PaymentSheet + Apple Pay, or USDC deposit to the contract). The job doesn't appear on the marketplace until it's funded.
11. **[MVP]** Job status timeline: Funded → Offered → Accepted → In progress → Submitted → Approved/Paid.
12. **[Stretch]** Choose between "first twin to accept" and "pick from the top 3 candidates."

### C. Matching (twin agent)
13. **[MVP]** Each new job gets embedded and compared with worker twin embeddings (vector search), then filtered by distance, availability, minimum pay and blocked categories.
14. **[MVP]** An LLM re-ranks the top candidates and writes the offer: why it's a fit, estimated time, estimated hourly rate, and the travel time.
15. **[MVP]** Offers go out one at a time, Uber-style. The first worker gets N seconds, and if they decline or the offer expires it goes to the next worker.
16. **[Stretch]** The twin checks the deadline against calendar free time and suggests a time slot ("You could do this Sat 9–11am").
17. **[Product]** Learn from accepts and declines (adjust ranking weights for each user).

### D. Push offer and accept/decline
18. **[MVP]** A time-sensitive push notification with **Accept / Decline** actions. Accept requires Face ID.
19. **[MVP]** A full-screen in-app offer card (the Uber look): pay in large text, map, distance, deadline, the twin's "why you" reason, and a countdown ring.
20. **[Stretch]** A Notification Content Extension so the rich card shows when the notification is long-pressed.
21. **[Stretch]** A **Live Activity** with a Dynamic Island countdown to the job deadline after the worker accepts.

### E. Doing the job and submitting proof
22. **[MVP]** **Capture with the in-app camera only** (no photos from the library). Each photo gets a stamp with the GPS location, a timestamp, and a **one-time code** that has to be visible in the frame or written on paper. That stops people from reusing old photos.
23. **[MVP]** A guided "before" capture when the worker starts. The "after" capture shows a ghost overlay of the before photo so the angles match.
24. **[MVP]** Location check-in when the worker starts and finishes (for in-person jobs).
25. **[MVP]** Links or files as proof for remote or digital jobs (Git repo, Figma link, PDF).
26. **[MVP]** **AI verification**: a vision LLM grades the evidence against the checklist and returns a pass/fail result with a confidence score and a short explanation for each item.
27. **[Stretch]** App Attest (DeviceCheck) so the server knows uploads come from a real, unmodified copy of our app.
28. **[Stretch]** Physical goods: a shipping label through EasyPost or Shippo, delivery tracking with a signature or delivery code, and a photo of the item next to the one-time code before it ships.

### F. Escrow, release and disputes
29. **[MVP]** A state machine on the server (section 4) decides when money moves. It's the only thing that can release or refund funds.
30. **[MVP]** If the AI passes the job, the poster gets a **review window** of 24–48h, or 2 minutes in the demo. If the poster doesn't respond, the money is **released automatically**.
31. **[MVP]** If the worker misses the deadline, the poster is refunded automatically.
32. **[Stretch]** Disputes: the poster has to point to a specific checklist item that failed. The AI reviews it again, then an admin makes the call, and the loser pays a small dispute fee.
33. **[Product]** A community jury for disputes, insurance for physical goods, and Stripe Identity (KYC) for high-value jobs.

### G. Payouts and wallet
34. **[MVP]** Worker payouts through Stripe Connect Express. Onboarding happens in an in-app Safari view (`SFSafariViewController`).
35. **[MVP]** A USDC escrow contract on Base Sepolia with `deposit(jobId)`, `release(jobId, worker)` (only the platform's arbiter key can call it), and `refund(jobId)` (the poster can call it after the deadline if the job hasn't been released).
36. **[MVP]** An earnings screen: pending (in escrow), paid out, and a USD/USDC breakdown.

### H. Trust and safety
37. **[MVP]** Two-way ratings after each job, and a reliability score per worker (accept rate × completion rate).
38. **[Stretch]** Report and block users, and send risky job descriptions (weapons, adult content, etc.) for manual approval.
39. **[Product]** ID verification and background checks for jobs inside someone's home.

---

## 3. Architecture

💡 **Reuse the stack from the HackGT project (Nudge, `AlanRoybal/hackgt`).** It's already AWS CDK + Lambda + DynamoDB + Bedrock + S3 Vectors, and an iOS package setup like NudgeKit. That saves hours of setup.

```
iOS (SwiftUI, iOS 17+)
 ├─ App/              Feature views: Onboarding, Twin, Offer, Job, Capture, Wallet, Post
 ├─ Packages/TwinKit  API client, models, Auth, EventKit availability, Camera/Proof capture
 ├─ NotificationContentExtension   rich offer card
 └─ WidgetExtension   Live Activity (job countdown)

Backend (AWS CDK)
 ├─ API Gateway + Lambda (TypeScript)
 │   auth/linkedin-callback, profile/ingest, jobs/create, jobs/fund,
 │   offers/respond, proof/submit, escrow/release, stripe/webhook, chain/webhook
 ├─ DynamoDB          Users, Twins, Jobs, Offers, Proofs, LedgerEvents
 ├─ S3                resumes, proof photos (presigned uploads)
 ├─ S3 Vectors        twin + job embeddings
 ├─ Bedrock           Claude (skill extraction, checklist, re-rank, vision grading), Titan embeddings
 ├─ Step Functions    offer cascade (timeouts), review-window timers, deadline refunds
 └─ SNS/APNs (token-based .p8 key)  push

Payments
 ├─ Stripe: PaymentIntents (poster), Connect Express (workers), Transfers, Refunds, webhooks
 └─ Base Sepolia: BountyEscrow.sol (Foundry), USDC test token, viem listener in Lambda
```

---

## 4. Job and escrow state machine

```
DRAFT ──fund──▶ FUNDED ──match──▶ OFFERED ──accept──▶ ACCEPTED ──start──▶ IN_PROGRESS
                  │                  │ decline/timeout → next candidate      │
                  │                  └ no candidates → FUNDED (re-match)     │
                  └ cancel → REFUNDED                                        ▼
                                                     SUBMITTED ──AI pass──▶ IN_REVIEW
                                                        │ AI fail → IN_PROGRESS (retry, max 2)
                                    IN_REVIEW ──approve / window expires──▶ RELEASED (paid)
                                    IN_REVIEW ──dispute──▶ DISPUTED ──▶ RELEASED | REFUNDED
                    ACCEPTED/IN_PROGRESS ──deadline passed──▶ REFUNDED
```
Every change is recorded in `LedgerEvents`, a log that's only ever added to. Money moves only from transitions handled in Step Functions or Lambda, never directly from a request made by the app.

---

## 5. Build schedule (~36h MHacks)

Assumes 4 people: **iOS-A** (worker app), **iOS-B** (poster app, camera and notifications), **Backend** (matching and AI), **Payments** (Stripe and the contract).

| Hours | iOS-A | iOS-B | Backend | Payments |
|---|---|---|---|---|
| 0–3 | Xcode project, TwinKit, design system | APNs keys, notification categories | CDK stack based on hackgt, DynamoDB tables | Stripe test account, Connect Express, Foundry project |
| 3–10 | LinkedIn OIDC + résumé upload, twin profile UI | Post-job flow, checklist editor | Skill extraction, checklist generator, embeddings | PaymentIntent + Apple Pay, webhook → FUNDED |
| 10–18 | Offer card, Accept/Decline (push + in-app) | Proof capture: one-time code, GPS, before/after overlay | Matching + re-ranking, offer cascade (Step Functions) | BountyEscrow.sol deploy + tests, USDC deposit from the app |
| 18–26 | EventKit availability, earnings screen | Job timeline, review screen | Vision grading, review-window timer, auto-release/refund | Transfers to Connect, contract release/refund wired up |
| 26–32 | Live Activity (stretch), polish | Gmail connect (stretch), polish | Seed data: 30 realistic jobs around Ann Arbor | Ledger checks, failure cases |
| 32–36 | **Demo rehearsal x5, record a backup video, Devpost** | | | |

---

## 6. Judging-table demo script (about 2 minutes)

1. Give the judge a TestFlight phone. They sign in with LinkedIn and upload their résumé, or we use a prepared profile, and their twin appears with their skills.
2. We post a job from a second phone: "Sketch a logo for a coffee shop on paper — $15." A checklist is generated and the job is funded with Apple Pay in Stripe test mode.
3. **The judge's phone buzzes** with a push notification: "$15 · 10 min · You're a match because: graphic design (LinkedIn)." They tap **Accept** with Face ID.
4. The judge sketches it at the table and photographs it with the one-time code visible. The AI grades it live against the checklist.
5. The review window ends after 2 minutes and the earnings screen shows "$15 paid," with the Stripe test dashboard on a laptop. Then we show the same job paid in USDC on the Base Sepolia block explorer.

💡 Backup: a fake lawn-mowing job with before and after photos we took earlier, to show location check-in and the matched-angle overlay.

---

## 7. Suggestions and risks

- 💡 **Push the twin and AI proof-of-work in the pitch, and keep payments in the background.** The judges are scoring innovation and technical complexity, not payment features. "AI proof of work" is the new part.
- 💡 **Crypto: testnet only, and keep it optional.** It adds a smart contract and wallet setup (one person's whole weekend). If time runs short, cut crypto first and keep Stripe.
- 💡 **Choose one market for launch**, such as "local tasks for college students in Ann Arbor." It makes the pitch concrete and matches the seed data.
- 💡 **Privacy is a selling point**: calendar data stays on the phone, raw email is never stored, and every inferred skill can be traced and deleted. Expect judges to ask about this.
- ⚠️ Notifications with Accept/Decline need a *real device*, because the simulator can't receive real APNs pushes reliably. Have 2–3 phones with TestFlight builds by hour 18.
- ⚠️ AI grading can be wrong or fooled. Present it as evidence that goes to a human review window, not a final decision, and say that clearly in the pitch.
- ⚠️ Seed both sides of the marketplace with realistic data so it doesn't look empty.
- ⚠️ Possible sponsor fits if you want them: Fetch.ai (twin as an agent + Payment Protocol), and any Stripe/Coinbase/Base track. These are optional, since you're aiming for the grand prize.

---

## 8. Open decisions
1. App name and branding.
2. Crypto at MHacks: build the contract, or Stripe stablecoins if the account has it, or cut it?
3. Gmail in the MVP or stretch? I recommend stretch, because Google setup time is high and the demo payoff is low.
4. Platform fee: I suggest 10% from the poster, shown at checkout.
