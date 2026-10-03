import SwiftUI
import SafariServices

struct EarningsView: View {
    @EnvironmentObject private var payments: WorkerPayments
    @State private var onboarding: PayoutSetup?

    var body: some View {
        List {
            if let earnings = payments.earnings {
                Section("USD") {
                    amount("Transferred to Stripe", cents: earnings.totals.usd.releasedCents, rail: "USD")
                    amount("Pending review or payment", cents: earnings.totals.usd.pendingCents, rail: "USD")
                    Text("A transfer credits your connected Stripe account. A bank payout is a separate step.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("USDC") {
                    amount("Sent to your wallet", cents: earnings.totals.usdc.releasedCents, rail: "USDC")
                    amount("Pending in escrow", cents: earnings.totals.usdc.pendingCents, rail: "USDC")
                }
                Section("Recent jobs") {
                    if earnings.entries.isEmpty { Text("No earnings yet.").foregroundStyle(.secondary) }
                    ForEach(earnings.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack { Text(entry.title).font(.headline); Spacer(); Text("\((Decimal(entry.amountCents) / 100).formatted()) \(entry.rail.uppercased())") }
                            Text(JobStatus.api(entry.status).rawValue).font(.subheadline).foregroundStyle(.secondary)
                            if let issue = entry.issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
                            if entry.rail == "usdc", let hash = entry.reference,
                               let url = URL(string: "https://sepolia.basescan.org/tx/\(hash)") { Link("View transaction", destination: url).font(.caption) }
                        }
                    }
                }
            } else if payments.busy { ProgressView("Loading earnings…") }
            Section("Payout setup") {
                Button("Set up Stripe payouts") { Task { if let url = await payments.onboardingURL() { onboarding = PayoutSetup(url: url) } } }
                Button("Connect USDC payout wallet") { Task { await payments.connectWallet() } }
                if let address = payments.profile?.walletAddress { Text(address).font(.caption.monospaced()).textSelection(.enabled) }
            }
            .disabled(payments.busy)
            if let message = payments.message {
                Section { Text(message).foregroundStyle(.secondary); Button("Try again") { Task { await payments.refresh() } } }
            }
        }
        .navigationTitle("Earnings")
        .task { await payments.refresh() }
        .refreshable { await payments.refresh() }
        .sheet(item: $onboarding, onDismiss: { Task { await payments.refresh() } }) { setup in PayoutBrowser(url: setup.url) }
    }
    private func amount(_ title: String, cents: Int, rail: String) -> some View {
        LabeledContent(title, value: "\((Decimal(cents) / 100).formatted()) \(rail)")
    }
}
private struct PayoutSetup: Identifiable { let id = UUID(); let url: URL }
private struct PayoutBrowser: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
#Preview { NavigationStack { EarningsView() }.environmentObject(WorkerPayments()) }
