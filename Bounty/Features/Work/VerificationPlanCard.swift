import SwiftUI

/// "How Bounty verifies this job": every check the server runs before paying, when it runs, what happens
/// if it fails, and what it records about the worker. The poster sees it before funding, the worker before
/// accepting and while working, so nobody is surprised by what's tracked.
struct VerificationPlanCard: View {
    enum Audience { case poster, worker }

    let plan: VerificationPlan
    let audience: Audience

    private static let stages: [(id: String, title: String)] = [("start", "To start"), ("proof", "With the proof"), ("review", "Before payment")]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(BountyColor.mintInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text(audience == .poster ? "How Bounty verifies this job" : "What Bounty checks")
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                    Text(plan.summary)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                }
            }

            ForEach(Self.stages, id: \.id) { stage in
                let signals = plan.signals.filter { $0.stage == stage.id }
                if !signals.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(stage.title.uppercased())
                            .bountyType(.caption)
                            .foregroundStyle(BountyColor.inkTertiary)
                        ForEach(signals) { signal in
                            SignalRow(signal: signal)
                        }
                    }
                }
            }

            Label(plan.privacy, systemImage: "lock.fill")
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkSecondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tintedPanel(BountyColor.field, radius: 14)
        }
        .padding(16)
        .borderedCard()
    }
}

private struct SignalRow: View {
    let signal: VerificationPlan.Signal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(BountyColor.lavenderInk)
                .frame(width: 32, height: 32)
                .background(BountyColor.lavenderSoft, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(signal.title)
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                    Spacer(minLength: 4)
                    Text(enforcement)
                        .bountyType(.caption)
                        .foregroundStyle(enforcementInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(enforcementFill, in: Capsule())
                }
                Text(signal.detail)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let collects = signal.collects {
                    Label("Records: \(collects)", systemImage: "eye")
                        .bountyType(.caption)
                        .foregroundStyle(BountyColor.inkTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch signal.id {
        case "on_site_start": "location.fill"
        case "on_site_check_in": "mappin.and.ellipse"
        case "photo_location": "location.viewfinder"
        case "fresh_photos": "camera.badge.clock"
        case "before_after": "square.split.2x1"
        case "deliverable": "doc.text.magnifyingglass"
        case "deadline": "calendar.badge.clock"
        default: "sparkles"
        }
    }

    private var enforcement: String {
        switch signal.enforcement {
        case "blocks": "Required"
        case "fails_item": "Item fails"
        default: "Poster reviews"
        }
    }

    private var enforcementFill: Color {
        signal.enforcement == "poster_reviews" ? BountyColor.cream : BountyColor.mint
    }

    private var enforcementInk: Color {
        signal.enforcement == "poster_reviews" ? BountyColor.creamInk : BountyColor.mintInk
    }
}

#Preview {
    ScrollView {
        VerificationPlanCard(
            plan: VerificationPlan(
                summary: "Verified on site: location at start, located photos, and AI review of 3 items.",
                signals: [
                    .init(id: "on_site_start", stage: "start", enforcement: "blocks", title: "On site to start",
                          detail: "Start only works within 200 m of 1200 S University Ave.", collects: "One GPS reading when the worker taps Start"),
                    .init(id: "photo_location", stage: "proof", enforcement: "poster_reviews", title: "Photos taken on site",
                          detail: "Any taken more than 400 m away send the job to the poster instead of paying automatically.", collects: "The location of each proof photo"),
                    .init(id: "ai_review", stage: "review", enforcement: "poster_reviews", title: "AI review, people decide doubts",
                          detail: "The AI checks 3 required items and must be at least 70% confident in each.", collects: nil),
                ],
                privacy: "Bounty never tracks location in the background. It reads GPS only when the worker taps Start, checks in, or takes a proof photo."
            ),
            audience: .poster
        )
        .padding()
    }
}
