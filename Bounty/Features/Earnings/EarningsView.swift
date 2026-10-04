import SwiftUI
import SafariServices

/// 17 Earnings.
struct EarningsView: View {
    @EnvironmentObject private var payments: WorkerPayments
    @State private var onboarding: PayoutSetup?
    private func amount(_ cents: Int) -> String { (Decimal(cents) / 100).formatted(.number.precision(.fractionLength(2))) }

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowYellow, height: 360)) {
            ScreenTitle(title: "Earnings") {
                IconButton(icon: .userRound, label: "Account") {}
            }
            .entrance(.top)

            StackCard(tone: .yellow, height: 180, bandTop: 135) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transferred")
                        .bountyType(.subheadStrong)
                    Text("$\(amount(payments.earnings?.totals.usd.releasedCents ?? 0))")
                        .bountyType(.moneyL)
                    Text("USDC \(amount(payments.earnings?.totals.usdc.releasedCents ?? 0)) to your wallet")
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkPill)
                    Chip(label: "USD and USDC", tone: .dark)
                        .padding(.top, 6)
                }
                .foregroundStyle(BountyColor.inkPrimary)
                .padding(.leading, 20)
                .padding(.top, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topTrailing) {
                    StickerView(sticker: .coins, size: 120)
                        .padding(.top, 18)
                        .padding(.trailing, 15)
                }
            }
            .entrance(.top)

            HStack(spacing: 10) {
                BalanceTile(label: "USD pending", amount: "$\(amount(payments.earnings?.totals.usd.pendingCents ?? 0))", background: BountyColor.grey, foreground: BountyColor.navy)
                BalanceTile(label: "USDC pending", amount: amount(payments.earnings?.totals.usdc.pendingCents ?? 0), background: BountyColor.cream, foreground: BountyColor.creamInk)
            }
            Text("Stripe transfers credit your connected account. Bank payouts happen separately.")
                .bountyType(.footnote)
            SectionHeader(title: "Activity")
            if let earnings = payments.earnings {
                if earnings.entries.isEmpty { Text("No earnings yet.").bountyType(.footnote) }
                ForEach(earnings.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        ActivityRow(sticker: .coins, tile: BountyColor.mint, title: entry.title,
                            detail: JobStatus.api(entry.status).rawValue,
                            amount: "\(amount(entry.amountCents)) \(entry.rail.uppercased())", settled: entry.status == "released")
                        if let issue = entry.issue { Text(issue).bountyType(.footnote) }
                        if entry.rail == "usdc", let hash = entry.reference,
                           let url = URL(string: "https://sepolia.basescan.org/tx/\(hash)") {
                            Link("View transaction", destination: url).bountyType(.footnote)
                        }
                    }.padding(14).borderedCard()
                }
            } else if payments.busy { ProgressView("Loading earnings…") }
            SectionHeader(title: "Payout setup")
            PillButton(title: "Set up Stripe payouts") {
                Task { if let url = await payments.onboardingURL() { onboarding = PayoutSetup(url: url) } }
            }.disabled(payments.busy)
            PillButton(title: "Connect USDC payout wallet", style: .secondary) {
                Task { await payments.connectWallet() }
            }.disabled(payments.busy)
            if let address = payments.profile?.walletAddress { Text(address).font(.caption.monospaced()).textSelection(.enabled) }
            if let message = payments.message {
                Text(message).bountyType(.footnote)
                Button("Try again") { Task { await payments.refresh() } }
            }
        }
        .task { await payments.refresh() }
        .refreshable { await payments.refresh() }
        .sheet(item: $onboarding, onDismiss: { Task { await payments.refresh() } }) { setup in PayoutBrowser(url: setup.url) }
    }
}

private struct PayoutSetup: Identifiable { let id = UUID(); let url: URL }
private struct PayoutBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct BalanceTile: View {
    let label: String
    let amount: String
    let background: Color
    let foreground: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).bountyType(.footnote)
            Text(amount).bountyType(.moneyM)
        }
        .foregroundStyle(foreground)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tintedPanel(background, radius: BountyRadius.row)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityRow: View {
    let sticker: Sticker
    let tile: Color
    let title: String
    let detail: String
    let amount: String
    let settled: Bool

    var body: some View {
        HStack(spacing: 12) {
            StickerTile(sticker: sticker, background: tile, size: 44, stickerSize: 34, radius: 13)
            TitleSubtitle(title: title, subtitle: detail)
            Text(amount)
                .bountyType(.subheadStrong)
                .foregroundStyle(settled ? BountyColor.greenInk : BountyColor.inkSecondary)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    EarningsView().environmentObject(WorkerPayments())
}
