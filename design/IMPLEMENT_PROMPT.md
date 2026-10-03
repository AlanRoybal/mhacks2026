Implement the Bounty iOS UI from the design handoff in `design/`.

1. Read `design/README.md` first, then `design/tokens.json`, then look at every PNG in `design/screens/`. `app-user-stories.md` and `bounty-twin-plan.md` describe the product behavior.
2. Replace the colors in `Bounty/Design/BountyTheme.swift` with the tokens. Add typography helpers that use the SF Pro mappings in `tokens.json`. Build the shared SwiftUI components listed in the README: pill ButtonStyle with pressed state, Chip, StackCard, ListRow, Tile, IconButton, Meter, SegmentedControl, Field, ProgressDots and the tab bar styling.
3. Add the stickers in `design/stickers/*.svg` to `Assets.xcassets` as vector image sets.
4. Build all 17 screens to match the PNGs pixel for pixel at 393×852, using mock data from `Bounty/Models/Job.swift`. Keep the five tabs in `RootTabView`. Put new views in the paths given in the README's screen table.
5. Add the page enter/exit, tab crossfade, press and meter animations from the README's Motion section, and respect Reduce Motion.
6. Wire navigation as described under "Prototype flows".
7. Don't add a résumé upload. The twin's sources are only LinkedIn, Gmail and Calendar.
8. Make sure it builds with `xcodegen generate && xcodebuild -scheme Bounty -destination 'platform=iOS Simulator,name=iPhone 16' build`. Capture simulator screenshots of each screen and compare them to the PNGs before you finish.
