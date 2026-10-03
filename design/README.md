# Bounty design handoff

This folder is the implementation source for the Bounty iOS UI. Each screen is in `screens/` as a 2x PNG, and the exact values are in `tokens.json`. You don't need Figma access to build from it.

- Figma file: https://www.figma.com/design/G5Oa2YOpCJe90ETNpwbWrl
- Clickable prototype with animations: https://www.figma.com/proto/G5Oa2YOpCJe90ETNpwbWrl?node-id=9-1010&starting-point-node-id=9%3A1010
- Style is based on [KeyaanVegdani/dex](https://github.com/KeyaanVegdani/dex): white canvas, pastel stacked cards, big bold black type, yellow pill buttons and flat sticker illustrations.

If you have the Figma MCP connected with Alan's account, `get_design_context` / `get_screenshot` work on the node IDs below. Otherwise, use the PNGs.

## Rules

- Build with SwiftUI on iOS 17 and Swift 6 (`project.yml`). Keep the five tabs in `RootTabView`: Home, Jobs, Post, Twin, Earnings.
- Replace the colors in `Bounty/Design/BountyTheme.swift` (blue, green, orange) with the tokens in `tokens.json`. Put them in an asset catalog or a `Color` extension, using names like `Color.brandYellow` and `Color.toneLavenderSoft`.
- Fonts: Figma uses Inter/Nunito only as stand-ins. **Use SF Pro.** The `swiftUI` field in `tokens.json` → `typography` gives the exact `Font` for each style. Money styles use `.rounded`.
- The twin learns from three sources: **LinkedIn (sign-in + profile PDF), Gmail (read-only) and Calendar (free/busy)**. There is no résumé upload. Don't add one.
- Color meaning: yellow = primary action, lavender/blue = twin and matching, green = verified/active/released, cream = jobs and proof, grey = pending/neutral, coral = urgent countdowns.
- Stickers in `stickers/` are flat SVGs. Add them to `Assets.xcassets` as SVG image sets with Preserve Vector Data turned on. Icons in `icons/` are Lucide (24pt, 2pt stroke, `currentColor`). SF Symbols with the same meaning are fine too.

## Screens

| # | Screen | PNG | Figma node | Swift destination |
|---|---|---|---|---|
| 01 | Welcome | `screens/01-welcome.png` | 5:1626 | `Features/Onboarding/OnboardingView.swift` |
| 02 | Profile import (Gmail, LinkedIn PDF, Calendar) | `screens/02-profile-import.png` | 5:1694 | Onboarding |
| 03 | Building your twin (auto-advances after 2.5 s) | `screens/03-building-your-twin.png` | 5:1817 | Onboarding |
| 04 | Twin review (Twin tab) | `screens/04-twin-review.png` | 5:1910 | `Features/Twin/TwinView.swift` |
| 05 | Availability & preferences | `screens/05-availability-preferences.png` | 5:2054 | Onboarding final step, also reachable from Twin |
| 06 | Home | `screens/06-home.png` | 5:115 | `Features/Home/HomeView.swift` |
| 07 | Push offer on lock screen (Accept/Decline actions) | `screens/07-push-offer-lock-screen.png` | 5:264 | `App/PushNotificationManager.swift` notification category |
| 08 | Offer (full screen, countdown) | `screens/08-offer.png` | 5:325 | new `Features/Offer/OfferView.swift` |
| 09 | Job detail (in progress, timeline) | `screens/09-job-detail-in-progress.png` | 5:2180 | new `Features/Jobs/JobDetailView.swift` (one adaptive view for every status) |
| 10 | Proof capture (camera, GPS/time, one-time code) | `screens/10-proof-capture.png` | 5:2301 | new `Features/Proof/ProofCaptureView.swift` |
| 11 | AI verification result | `screens/11-ai-verification.png` | 5:2382 | Proof |
| 12 | Post a job | `screens/12-post-a-job.png` | 5:1275 | `Features/Post/CreateJobView.swift` |
| 13 | Proof checklist (AI-drafted, editable) | `screens/13-proof-checklist.png` | 5:1419 | Post flow step 2 |
| 14 | Fund the job (fee, Card/Apple Pay or USDC, escrow) | `screens/14-fund-the-job.png` | 5:1543 | Post flow step 3 |
| 15 | Review proof (before/after, approve or dispute) | `screens/15-review-proof.png` | 5:2462 | Job detail, requester mode |
| 16 | Jobs (Working / Posted / Done) | `screens/16-jobs.png` | 5:2603 | `Features/Jobs/JobsView.swift` |
| 17 | Earnings | `screens/17-earnings.png` | 5:2743 | `Features/Earnings/EarningsView.swift` |

All sample content (titles, prices, copy) matches `Bounty/Models/Job.swift` and the PNGs. Use the PNG text as the copy source.

## Layout

- Frames are 393×852 (iPhone 15/16). Content is 353pt wide with 20pt side margins and starts 62pt from the top. Sections are spaced 14–20pt apart.
- Bottom actions are pinned above the home indicator, or above the 83pt tab bar on tab screens, with a 12pt gap. Use `.safeAreaInset(edge: .bottom)`.
- Some screens have a top gradient called "Background glow": a pastel color fading to clear over about 360–460pt, behind the content.

## Components (Figma component → SwiftUI)

- **Button** (`Style` = Primary, Secondary, Dark, Outline; `State` = Default, Pressed): a 56pt capsule with Body Strong text and an optional 20pt leading icon. Make it a `ButtonStyle` that applies the pressed fill and `scaleEffect(0.97)`.
- **Chip** (`Tone` = Lavender, Cream, Mint, Sky, Grey, Yellow, Dark, Coral): a 28pt capsule with 12pt horizontal padding, Footnote text, and width that fits the label.
- **Stack card**: dex's layered card. The front card has a 28pt radius and a tone fill. A large ellipse "band" in the band color covers its lower part, clipped to the card. Behind it, a back card is inset 12pt on each side and offset 12pt down, in the back color. The tone triples are in `tokens.json` → `stackCard.tones`.
- **List row**: icon tile or avatar, then title and subtitle, then a trailing value. 14/16pt padding, 20pt radius, 1pt `surface/divider` border.
- **Tile**: a sticker on a pastel square. The radius is 30% of the size, 52pt by default.
- **Icon button**: a 44pt circle in `surface/pill` with a 22pt icon.
- **Meter**: an 8pt capsule track with a colored fill.
- **Segmented control**: a `surface/pill` track with 4pt padding. The selected segment is white with a soft shadow.
- **Toggle**: a 51×31 green switch, i.e. a tinted `Toggle`.
- **Field**: Footnote label above a 52pt `surface/field` box with a 16pt radius.
- **Progress dots**: done = 12pt green dot, current = 36×12 yellow capsule, upcoming = 12pt grey dot.
- **Tab bar**: five items. The active item has a pill background. Post is always a yellow circle with a plus.

## Motion

The full spec is in `tokens.json` → `motion` and on the Figma Foundations board under "Motion". You can watch it in the prototype link above.

- **Page enter:** content moves up from +36pt and fades in, staggered by section (60 ms apart) with `.spring(response: 0.5, dampingFraction: 0.82)`. Bottom actions come up from +48pt last.
- **Page exit:** content moves to −24pt and fades, and bottom actions drop 40pt. Use `.easeIn(duration: 0.2)`, then the next screen enters. One way to do it: `.transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 36)), removal: .opacity.combined(with: .offset(y: -24))))`.
- **Tab switch:** a 0.15 s crossfade, then that tab's page enter. The tab bar never moves.
- **Press:** pressed fill plus scale 0.97, using spring(0.25, 0.7).
- **Meters:** fill from 0 with spring(0.6, 0.9) after a 0.1 s delay.
- **Reduce Motion:** if `accessibilityReduceMotion` is on, drop the offsets and scale and keep 150 ms opacity fades.

## Prototype flows (navigation map)

- **Onboarding:** 01 → 02 → 03 → (auto) 05 → 04 (Twin tab). Back from 02 → 01 and from 05 → 02.
- **Worker:**
  - 06 has three exits: View offer → 08, the bell → 07, and the vintage desk row → 09.
  - From 07 or 08, Accept (with Face ID) → 09, and Decline → 06.
  - Then 09 Start proof → 10, shutter → 11, Done → 06.
- **Requester:** 12 → 13 → 14, Pay → 16. From 16, the calculus worksheet row → 15, then Approve → 17.
- **Tabs** on 04, 06, 12, 16 and 17 switch to Home 06, Jobs 16, Post 12, Twin 04 and Earnings 17.
