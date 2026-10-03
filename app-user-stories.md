# Bounty Twin user stories and app pages

Bounty Twin is a two-sided marketplace in one iOS app. A user can post jobs, work jobs, or do both. The digital twin builds a worker profile, finds suitable jobs, and explains each match.

## Actors

1. Worker: builds a digital twin, receives offers, completes jobs, submits proof, and receives payouts.
2. Requester: posts and funds jobs, agrees on proof requirements, reviews completed work, and approves payment or disputes a checklist item.
3. Platform: extracts skills, matches jobs to workers, manages offer expiration, grades evidence, and controls escrow state transitions.
4. Admin, stretch only: reviews disputed jobs and moderates reports or risky job posts.

A single account should support both worker and requester actions. Users should not choose a permanent role during onboarding.

## User stories

### Account and digital twin

| ID | Priority | User story | Connects to | Required UI |
|---|---|---|---|---|
| US-01 | MVP | As a user, I can sign in with LinkedIn or Apple so I can create an account. | Starts onboarding | Welcome, sign-in |
| US-02 | MVP | As a worker, I can upload a résumé, LinkedIn PDF, or LinkedIn export so the app can identify my experience. | Feeds skill extraction | Profile import |
| US-03 | MVP | As a worker, I can see extraction progress and correct an upload error. | Leads to twin review | Processing state |
| US-04 | MVP | As a worker, I can review every inferred skill, including its source and confidence, so I understand what my twin knows. | Drives matching | Twin profile |
| US-05 | MVP | As a worker, I can add, edit, or remove skills so inaccurate information does not affect my offers. | Updates twin embedding | Skill editor |
| US-06 | MVP | As a worker, I can connect my calendar so my twin avoids jobs I cannot complete. | Feeds availability filter | Calendar permission |
| US-07 | MVP | As a worker, I can set minimum pay, travel radius, work type, blocked categories, and quiet hours. | Filters candidate jobs and notifications | Work preferences |
| US-08 | MVP | As a worker, I can see whether my twin is ready to find work and what information is missing. | Leads into worker home | Twin readiness |
| US-09 | Stretch | As a worker, I can connect Gmail or Outlook so the twin can infer skills not listed on my résumé. | Adds sourced skills | Connected accounts |
| US-10 | Stretch | As a worker, I can ask why my twin selected or skipped a job and correct its reasoning. | Feeds personalized ranking | Twin chat |

```text
Sign in
  -> Import résumé or LinkedIn data
  -> Extract skills
  -> Review twin
  -> Add availability and preferences
  -> Twin becomes eligible for matching
```

### Posting and funding a job

| ID | Priority | User story | Connects to | Required UI |
|---|---|---|---|---|
| US-11 | MVP | As a requester, I can create a job with a title, description, category, photos, location, deadline, and payment amount. | Creates a draft | Create job |
| US-12 | MVP | As a requester, I can mark a job as remote or in person so the correct matching and proof rules apply. | Controls location requirements | Location picker |
| US-13 | MVP | As a requester, I can receive an AI-generated acceptance checklist so completion is defined before the job begins. | Defines proof capture and grading | Checklist review |
| US-14 | MVP | As a requester, I can edit the checklist and required evidence before funding. | Finalizes the work agreement | Checklist editor |
| US-15 | MVP | As a requester, I can review the job price, platform fee, and total charge. | Leads to payment | Checkout |
| US-16 | MVP | As a requester, I can fund the job with Apple Pay or Stripe so it can be offered to workers. | Moves `DRAFT` to `FUNDED` | Payment sheet |
| US-17 | MVP | As a requester, I can see the job's current status and history. | Tracks matching through payment | Job detail and timeline |
| US-18 | MVP | As a requester, I can cancel a funded job before a worker accepts it and receive a refund. | Moves eligible job to `REFUNDED` | Cancel confirmation |
| US-19 | Stretch | As a requester, I can fund a job with USDC. | Alternative escrow rail | Wallet connection |
| US-20 | Stretch | As a requester, I can choose whether the first matching worker gets the job or I select from three candidates. | Changes offer flow | Matching preference |

The checklist should be locked when the job is funded or accepted so neither party can quietly change the requirements.

```text
Create draft
  -> Generate proof checklist
  -> Requester edits and confirms checklist
  -> Checkout
  -> Funded job enters matching
```

### Matching and offers

| ID | Priority | User story | Connects to | Required UI |
|---|---|---|---|---|
| US-21 | MVP | As a worker, I only receive jobs that meet my pay, distance, availability, category, and work-type preferences. | Uses twin and job data | No separate page |
| US-22 | MVP | As a worker, I can see why my twin thinks a job fits me. | Helps the worker decide | Offer card |
| US-23 | MVP | As a worker, I can see pay, estimated time, effective hourly rate, distance, travel time, deadline, and required proof. | Supports informed acceptance | Offer detail |
| US-24 | MVP | As a worker, I can accept an offer before its timer expires. | Moves `OFFERED` to `ACCEPTED` | Offer card, Face ID prompt |
| US-25 | MVP | As a worker, I can decline an offer without opening the full app. | Sends offer to next candidate | Notification action |
| US-26 | MVP | As a worker, I can see when another worker accepted first or when my offer expired. | Resolves offer races | Expired state |
| US-27 | Stretch | As a worker, I can see a suggested calendar slot for completing the job. | Helps schedule accepted work | Offer schedule section |

```text
Funded job
  -> Filter eligible twins
  -> Rank candidates
  -> Send timed offer to candidate 1
      -> Accept: assign job
      -> Decline or expire: offer candidate 2
      -> No candidates: return to funded and retry later
```

Accept must be an atomic server operation. Two devices may respond close together, but only one worker should receive the assignment.

### Notifications and offer handling

| ID | Priority | User story | Connects to | Required UI |
|---|---|---|---|---|
| US-28 | MVP | As a worker, I receive a time-sensitive notification when my twin finds a job. | Opens or resolves offer | System notification |
| US-29 | MVP | As a worker, I can accept from the notification after Face ID authentication. | Assigns the job | Notification action |
| US-30 | MVP | As a worker, I can decline from the notification. | Advances offer cascade | Notification action |
| US-31 | MVP | As a worker, I can open a full offer card to inspect the map, checklist, and match explanation. | Leads to accept or decline | Full-screen offer |
| US-32 | Stretch | As a worker, I can see the rich offer card by long-pressing the notification. | Faster review | Notification extension |
| US-33 | Stretch | As a worker, I can track an accepted job through a Live Activity. | Leads into job execution | Lock Screen and Dynamic Island |

The push notification and in-app offer should represent the same server-side offer. The server's expiration time is authoritative, not the device countdown.

### Completing the job and submitting proof

| ID | Priority | User story | Connects to | Required UI |
|---|---|---|---|---|
| US-34 | MVP | As a worker, I can review the agreed checklist before starting work. | Prevents misunderstandings | Accepted job detail |
| US-35 | MVP | As a worker, I can check in at the job location. | Moves job to `IN_PROGRESS` | Start job |
| US-36 | MVP | As a worker, I can see the one-time code required in proof photos. | Prevents photo reuse | Proof instructions |
| US-37 | MVP | As a worker, I can capture required before photos using the in-app camera. | Creates baseline evidence | Guided camera |
| US-38 | MVP | As a worker, I can use a ghost overlay to match the original angle in after photos. | Improves evidence quality | Guided camera |
| US-39 | MVP | As a worker, I can see whether location, timestamp, and one-time-code checks passed before submitting. | Catches errors early | Evidence review |
| US-40 | MVP | As a remote worker, I can submit links or files instead of location-based photos. | Supports digital work | Link and file proof |
| US-41 | MVP | As a worker, I can submit completed evidence for AI review. | Moves job to `SUBMITTED` | Submit proof |
| US-42 | MVP | As a worker, I can see which checklist items passed or failed and why. | Leads to review or retry | Verification results |
| US-43 | MVP | As a worker, I can replace failed evidence and retry up to two times. | Returns job to `IN_PROGRESS` | Retry flow |

```text
In-person job:
check-in -> before photos -> work -> after photos -> final check-in -> submit

Remote job:
start -> upload file or link -> submit
```

### Review, payment, and refunds

| ID | Priority | User story | Connects to | Required UI |
|---|---|---|---|---|
| US-44 | MVP | As a requester, I receive a notification when proof is ready to review. | Opens submitted job | Notification |
| US-45 | MVP | As a requester, I can compare each checklist item with its submitted evidence and AI result. | Supports approval | Review submission |
| US-46 | MVP | As a requester, I can approve completed work. | Moves `IN_REVIEW` to `RELEASED` | Approve confirmation |
| US-47 | MVP | As a worker, I receive payment automatically if the requester does not respond before the review window ends. | Prevents indefinite holds | Review countdown |
| US-48 | MVP | As a requester, I receive a refund if an accepted job misses its deadline. | Moves job to `REFUNDED` | Refunded job state |
| US-49 | MVP | As either party, I can see every job and payment status change in a timeline. | Exposes ledger history | Job timeline |
| US-50 | Stretch | As a requester, I can dispute a specific failed checklist item. | Moves job to `DISPUTED` | Dispute form |
| US-51 | Stretch | As an admin, I can inspect the job, checklist, evidence, AI result, and event history before deciding a dispute. | Releases or refunds funds | Admin dispute detail |

The AI recommends whether evidence passes. It should not release money immediately after returning a positive result. The requester gets a review window, followed by automatic release.

### Earnings, payouts, and ratings

| ID | Priority | User story | Connects to | Required UI |
|---|---|---|---|---|
| US-52 | MVP | As a worker, I can complete Stripe Connect onboarding so I can receive payouts. | Required before withdrawal | Payout setup |
| US-53 | MVP | As a worker, I can see pending escrow, available earnings, and paid earnings. | Summarizes completed jobs | Earnings |
| US-54 | MVP | As a worker, I can distinguish USD earnings from USDC earnings. | Supports both payment rails | Earnings breakdown |
| US-55 | MVP | As a worker, I can open an earning to see its related job and payment history. | Links wallet to work | Transaction detail |
| US-56 | MVP | As a requester, I can rate a worker after the job is released or refunded. | Updates worker trust | Rating sheet |
| US-57 | MVP | As a worker, I can rate a requester after the job closes. | Updates requester trust | Rating sheet |
| US-58 | MVP | As a worker, I can see my acceptance rate, completion rate, and reliability score. | Influences trust and possibly matching | Profile stats |
| US-59 | Stretch | As a user, I can report or block another user. | Sends case to moderation | Report and block sheet |

Payment and rating stories only unlock after terminal states such as `RELEASED` or `REFUNDED`.

## Connected journeys

### Worker journey

```text
US-01 Sign in
  -> US-02 Import experience
  -> US-04 Review twin
  -> US-06 Add availability
  -> US-07 Set preferences
  -> US-28 Receive offer
  -> US-23 Review details
  -> US-24 Accept
  -> US-34 Review checklist
  -> US-35 Start job
  -> US-37/38 Capture evidence
  -> US-41 Submit
  -> US-42 See verification
  -> US-47 Payment releases
  -> US-53 See earnings
  -> US-57 Rate requester
```

### Requester journey

```text
US-11 Create job
  -> US-13 Generate checklist
  -> US-14 Confirm requirements
  -> US-15 Review total
  -> US-16 Fund job
  -> US-17 Track matching
  -> Worker completes job
  -> US-44 Receive review alert
  -> US-45 Review proof
  -> US-46 Approve
  -> US-56 Rate worker
```

### Server-controlled job flow

```text
DRAFT
  -> FUNDED
  -> OFFERED
  -> ACCEPTED
  -> IN_PROGRESS
  -> SUBMITTED
  -> IN_REVIEW
  -> RELEASED
```

Alternate paths:

```text
OFFERED -> declined or expired -> next worker
FUNDED -> requester cancels -> REFUNDED
SUBMITTED -> AI fails -> IN_PROGRESS for retry
ACCEPTED or IN_PROGRESS -> deadline passes -> REFUNDED
IN_REVIEW -> dispute -> DISPUTED -> RELEASED or REFUNDED
```

## App pages

### Navigation

Use a five-item tab bar:

1. Home
2. Jobs
3. Post
4. Twin
5. Earnings

The profile icon in the Home or Twin navigation bar opens account settings. This avoids adding a sixth top-level destination.

### Authentication and onboarding

1. Welcome
   - Product explanation
   - LinkedIn sign-in
   - Sign in with Apple
2. Profile import
   - Résumé upload
   - LinkedIn PDF upload
   - LinkedIn ZIP upload
   - Skip with manual setup
3. Import processing
   - Upload progress
   - Skill extraction progress
   - Retry state
4. Twin review
   - Extracted roles, skills, education, and certifications
   - Source and confidence for each item
   - Add, edit, and remove controls
5. Availability setup
   - Calendar permission
   - Inferred weekly availability
   - Manual corrections
6. Work preferences
   - Minimum pay
   - Travel radius
   - Remote or in-person
   - Blocked categories
   - Quiet hours

Onboarding finishes at the Twin page, where the user can see that matching is active.

### Home and job management

7. Home
   - Active jobs
   - Offers needing attention
   - Jobs awaiting review
   - Twin status
   - Recent earnings
8. Jobs
   - Segmented control for Working, Posted, and Completed
   - Status chips
9. Job detail
   - Actions based on status and ownership
   - Checklist
   - Deadline
   - Other party
   - Status timeline
   - Payment status

Use one adaptive Job Detail page instead of separate pages for every state.

### Posting

10. Create job
    - Details
    - Photos
    - Category
    - Location or remote
    - Deadline
    - Payment
11. Checklist review
    - AI-generated checklist
    - Required evidence
    - Add, edit, delete, and reorder items
12. Checkout
    - Job amount
    - Platform fee
    - Total
    - USD or USDC selection
    - Apple Pay or card
13. Job posted confirmation
    - Funded status
    - Matching status
    - Link to job timeline

The confirmation can be a sheet instead of a permanent page.

### Offers

14. Full-screen offer
    - Large payment amount
    - Countdown
    - Match reason
    - Estimated duration and hourly rate
    - Map and travel time
    - Deadline
    - Checklist preview
    - Accept and decline
15. Offer outcome
    - Accepted
    - Declined
    - Expired
    - Already taken

Use a transient state on the offer page rather than four separate pages.

### Doing the work

16. Accepted job
    - Checklist
    - Start job
    - Contact or coordination information
    - Deadline
    - Issue reporting rules
17. Proof instructions
    - Required shots or files
    - One-time code
    - Location requirements
    - Explanation of why library photos are unavailable
18. Guided camera
    - Before or after mode
    - Angle guide
    - Ghost overlay
    - GPS and timestamp status
    - One-time-code reminder
19. Evidence review
    - Captured images, links, and files
    - Checklist coverage
    - Missing evidence warnings
    - Submit button
20. Verification results
    - Pass or fail per checklist item
    - Confidence and explanation
    - Retry action
    - Review-window status

### Requester review

21. Review submission
    - Checklist and associated evidence
    - AI result for each item
    - Before and after comparison
    - Approve
    - Dispute, if included
22. Dispute form, stretch
    - Select checklist item
    - Explain the failure
    - Confirm dispute fee

### Twin and earnings

23. Twin profile
    - Skills
    - Experience
    - Sources
    - Confidence
    - Readiness
    - Reliability score
24. Skill editor
    - Name
    - Experience level
    - Source
    - Delete action
25. Earnings
    - Pending
    - Available or released
    - Paid
    - USD and USDC breakdown
26. Transaction detail
    - Amount
    - Job
    - Payment rail
    - Status history
    - Stripe or chain reference

### Settings

27. Account and settings
    - Identity
    - Notification settings
    - Connected calendar
    - Connected email, if built
    - Work preferences
    - Payout account
    - Privacy and data deletion
    - Sign out
28. Stripe payout onboarding
    - Explanation page
    - Opens Stripe Connect in `SFSafariViewController`
    - Return and status state

## MVP page cut

Twenty-eight destinations are too many to design as independent screens during a 36-hour hackathon. The MVP can use 14 primary screens:

1. Welcome
2. Profile import
3. Twin setup and review
4. Preferences and calendar
5. Home
6. Jobs list
7. Adaptive job detail and timeline
8. Create job
9. Checklist review
10. Checkout
11. Full-screen offer
12. Guided proof capture and evidence review
13. Requester proof review
14. Earnings

Skill editing, transaction details, offer outcomes, settings, ratings, and confirmations can be sheets or modes inside those screens.

## Product rules to settle before implementation

1. Checklist locking: lock the checklist once the job is funded or accepted. If it changes, both parties should explicitly agree.
2. Payout readiness: decide whether a worker can accept before finishing Stripe Connect onboarding. Requiring payout setup before acceptance is simpler for the demo.
3. Offer races: the backend must atomically award the job to one worker. Face ID success alone does not mean the job was assigned.
4. Cancellation rules: define what happens if the requester cancels after acceptance. The current state machine only covers cancellation before acceptance.
5. Worker withdrawal: define whether a worker can leave an accepted job and whether it affects reliability.
6. Proof failure: specify whether the two-retry limit applies to the whole submission or each checklist item.
7. No-match behavior: give the requester a way to expand the radius, raise the pay, extend the deadline, or request a refund.
8. Platform fee: show the fee before funding. The current plan suggests charging the requester 10 percent.
9. AI authority: present AI verification as a recommendation followed by human review.
10. Demo scope: build the Stripe path first. USDC, Gmail, Live Activities, disputes, and rich notification extensions can be cut without breaking the main story. The strongest demo loop is twin creation, matching, proof capture, AI review, and payment release.
