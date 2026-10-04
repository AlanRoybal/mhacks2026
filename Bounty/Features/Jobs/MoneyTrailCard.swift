import SwiftUI
import TwinKit

/// "Follow the money" (`GET /jobs/:id/money`): charged → held in escrow → released → paid, or refunded,
/// each with the Stripe or chain reference that proves it, plus how fast the payout landed.
struct MoneyTrailCard: View {
    @Environment(AppServices.self) private var services
    @Environment(\.openURL) private var openURL
    let jobId: String
    /// Re-fetch when the job's status changes.
    var refreshKey: String = ""

    @State private var trail: MoneyTrail?

    var body: some View {
        Group {
            if let trail, !trail.steps.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        IconGlyph(icon: .shieldCheck, size: 18)
                        Text("Follow the money")
                            .bountyType(.bodyStrong)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let seconds = trail.timeToPaidSeconds {
                            Chip(label: "Paid in \(PayoutSpeed.text(seconds))", tone: .mint)
                        }
                    }
                    .foregroundStyle(BountyColor.inkPrimary)

                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(trail.steps.enumerated()), id: \.offset) { index, step in
                            MoneyStepRow(step: step, isLast: index == trail.steps.count - 1) { url in openURL(url) }
                        }
                    }

                    Text(trail.rail == "usdc"
                         ? "Each reference is a Base Sepolia transaction you can check on Basescan."
                         : "References are Stripe IDs. Bounty never touches the money until the work is verified.")
                        .bountyType(.caption)
                        .foregroundStyle(BountyColor.inkTertiary)
                }
                .padding(16)
                .borderedCard()
                .transition(.opacity)
            } else {
                // A real (zero-height) view, so the load below runs: SwiftUI skips .task on an empty Group.
                Color.clear.frame(height: 0)
            }
        }
        .task(id: "\(jobId)|\(refreshKey)") {
            guard let api = services.api, let fresh: MoneyTrail = try? await api.request(.get, "jobs/\(jobId)/money") else { return }
            withAnimation(Motion.press) { trail = fresh }
        }
    }
}

private struct MoneyStepRow: View {
    let step: MoneyTrail.Step
    let isLast: Bool
    let open: (URL) -> Void

    private var style: (icon: BountyIcon, tint: Color, ink: Color) {
        switch step.kind {
        case "charged": (.wallet, BountyColor.sky, BountyColor.skyInk)
        case "held": (.lock, BountyColor.cream, BountyColor.creamInk)
        case "released": (.check, BountyColor.lavenderSoft, BountyColor.lavenderInk)
        case "paid": (.zap, BountyColor.mint, BountyColor.mintInk)
        default: (.refresh, BountyColor.pill, BountyColor.inkSecondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                IconGlyph(icon: style.icon, size: 16)
                    .foregroundStyle(style.ink)
                    .frame(width: 32, height: 32)
                    .background(style.tint, in: Circle())
                if !isLast {
                    BountyColor.divider.frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(step.label)
                    .bountyType(.subheadStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
                Text(step.detail)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
                Text(step.at.formatted(date: .abbreviated, time: .standard))
                    .bountyType(.caption)
                    .foregroundStyle(BountyColor.inkTertiary)
                if let reference = step.reference {
                    if let url = step.referenceUrl.flatMap(URL.init(string:)) {
                        Button { open(url) } label: {
                            Text(reference).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        }
                        .foregroundStyle(BountyColor.lavenderInk)
                    } else {
                        Text(reference).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(BountyColor.inkSecondary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.bottom, isLast ? 0 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

struct MoneyTrail: Decodable, Sendable {
    struct Step: Decodable, Sendable {
        /// charged, held, released, paid, refund_decided or refunded.
        let kind: String
        let label: String
        let detail: String
        let at: Date
        let amount: Decimal?
        let reference: String?
        let referenceUrl: String?
    }

    let rail: String
    let steps: [Step]
    let timeToPaidSeconds: Int?
}

/// "4 s", "2 min", "1 h 5 min": how long a payout took after approval.
enum PayoutSpeed {
    static func text(_ seconds: Int) -> String {
        switch seconds {
        case ..<1: "under 1 s"
        case ..<60: "\(seconds) s"
        case ..<3600: "\(seconds / 60) min"
        default: "\(seconds / 3600) h\(seconds % 3600 / 60 > 0 ? " \(seconds % 3600 / 60) min" : "")"
        }
    }
}
