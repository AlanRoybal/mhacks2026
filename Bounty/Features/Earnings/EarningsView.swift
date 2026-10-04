import SwiftUI
import SafariServices

/// 17 Earnings. USD marketplace earnings and Stripe payouts come from the main backend
/// (`MarketplaceEarnings`); the USDC wallet and its settlements come from the payments server (`WorkerPayments`).
struct EarningsView: View {
    @Environment(AppServices.self) private var services
    @EnvironmentObject private var payments: WorkerPayments
    @State private var earnings = MarketplaceEarnings()
    @State private var onboarding: PayoutSetup?
    @State private var selected: EarningItem?
    @State private var showsSettings = false
    @State private var showsIncomeStatement = false
    @State private var trust: WorkerTrustScore?
    private func amount(_ cents: Int) -> String { (Decimal(cents) / 100).formatted(.number.precision(.fractionLength(2))) }
    private func usd(_ value: Decimal?) -> String { (value ?? 0).formatted(.currency(code: "USD")) }

    private var usdTotals: EarningsSummary.CurrencyTotals? { earnings.summary?.totals(for: "USD") }
    private var usdcReleasedCents: Int { payments.earnings?.totals.usdc.releasedCents ?? 0 }
    private var usdcPendingCents: Int { payments.earnings?.totals.usdc.pendingCents ?? 0 }

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowYellow, height: 360), alwaysBounces: true) {
            ScreenTitle(title: "Earnings") {
                IconButton(icon: .userRound, label: "Account") { showsSettings = true }
            }
            .entrance(.top)

            StackCard(tone: .yellow, height: 180, bandTop: 135) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Paid to you")
                        .bountyType(.subheadStrong)
                    Text(usd(usdTotals?.paid))
                        .bountyType(.moneyL)
                    Text("USDC \(amount(usdcReleasedCents)) to your wallet")
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkPill)
                    if let seconds = earnings.summary?.averageTimeToPaidSeconds {
                        Chip(label: "Paid \(PayoutSpeed.text(seconds)) after approval", tone: .dark)
                            .padding(.top, 6)
                    } else {
                        Chip(label: "USD and USDC", tone: .dark)
                            .padding(.top, 6)
                    }
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
                BalanceTile(label: "USD in escrow", amount: usd(usdTotals?.pending), background: BountyColor.grey, foreground: BountyColor.navy)
                BalanceTile(label: "USD paying out", amount: usd(usdTotals?.releasing), background: BountyColor.mint, foreground: BountyColor.mintInk)
                BalanceTile(label: "USDC pending", amount: amount(usdcPendingCents), background: BountyColor.cream, foreground: BountyColor.creamInk)
            }
            .entrance(.rest(0))

            if let trust {
                TrustCard(trust: trust)
                    .entrance(.rest(1))
            }

            payoutPanel
                .entrance(.rest(1))

            if let summary = earnings.summary {
                TaxJarCard(summary: summary) { percent in
                    Task { await earnings.setTaxSetAside(percent, api: services.api) }
                }
                .entrance(.rest(1))

                Button { showsIncomeStatement = true } label: {
                    HStack(spacing: 12) {
                        StickerTile(sticker: .shield, background: BountyColor.lavenderSoft, size: 44, stickerSize: 34, radius: 13)
                        TitleSubtitle(title: "Proof of income", subtitle: "A verified statement for landlords and lenders")
                        IconGlyph(icon: .navigation, size: 18).foregroundStyle(BountyColor.inkSecondary)
                    }
                    .padding(14)
                    .borderedCard(radius: BountyRadius.row)
                }
                .buttonStyle(PressableStyle())
                .entrance(.rest(1))
            }

            SectionHeader(title: "Activity")
            if let items = earnings.summary?.items {
                if items.isEmpty && (payments.earnings?.entries.isEmpty ?? true) {
                    Text("No earnings yet. Accepted jobs show up here.").bountyType(.footnote)
                }
                ForEach(items) { item in
                    Button { selected = item } label: {
                        ActivityRow(sticker: .coins, tile: item.status == "paid" ? BountyColor.mint : BountyColor.grey, title: item.title,
                                    detail: item.statusText, amount: item.amountText, settled: item.status == "paid")
                    }
                    .buttonStyle(PressableStyle())
                }
            } else if earnings.isLoading { ProgressView("Loading earnings…") }

            // USDC jobs settle through the payments server.
            ForEach(payments.earnings?.entries ?? []) { entry in
                VStack(alignment: .leading, spacing: 6) {
                    ActivityRow(sticker: .coins, tile: BountyColor.cream, title: entry.title,
                        detail: JobStatus.api(entry.status).rawValue,
                        amount: "\(amount(entry.amountCents)) \(entry.rail.uppercased())", settled: entry.status == "released")
                    if let issue = entry.issue { Text(issue).bountyType(.footnote) }
                    if entry.rail == "usdc", let hash = entry.reference,
                       let url = URL(string: "https://sepolia.basescan.org/tx/\(hash)") {
                        Link("View transaction", destination: url).bountyType(.footnote)
                    }
                }.padding(14).borderedCard()
            }

            SectionHeader(title: "USDC payouts")
            PillButton(title: "Connect USDC payout wallet", style: .secondary) {
                Task { await payments.connectWallet() }
            }.disabled(payments.busy)
            if let address = payments.profile?.walletAddress { Text(address).font(.caption.monospaced()).textSelection(.enabled) }
            ForEach([earnings.message, payments.message].compactMap { $0 }, id: \.self) { message in
                Text(message).bountyType(.footnote).foregroundStyle(BountyColor.red)
            }
        }
        .task { await reload() }
        .refreshable { await reload() }
        .sheet(item: $onboarding, onDismiss: { Task { await earnings.syncPayouts(api: services.api) } }) { setup in PayoutBrowser(url: setup.url) }
        .sheet(item: $selected) { item in TransactionDetailView(item: item) }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        .sheet(isPresented: $showsIncomeStatement) { IncomeStatementSheet() }
        // Stripe sends the worker back to bounty://wallet when onboarding ends.
        .onReceive(NotificationCenter.default.publisher(for: .payoutSetupReturned)) { _ in onboarding = nil }
    }

    @ViewBuilder
    private var payoutPanel: some View {
        let status = earnings.summary?.payouts
        if status?.payoutsEnabled == true {
            Label("Stripe payouts are on. Approved jobs transfer to your Stripe account; bank payouts follow Stripe\u{2019}s schedule.", icon: .badgeCheck)
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.mintInk)
                .padding(14)
                .tintedPanel(BountyColor.mint, radius: BountyRadius.row)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text(status?.stripeConnected == true ? "Finish payout setup" : "Set up payouts to get offers").bountyType(.bodyStrong)
                Text("Your twin only gets matched with paid jobs once Stripe can pay you. It takes a few minutes in Stripe\u{2019}s secure form.")
                    .bountyType(.footnote)
                PillButton(title: status?.stripeConnected == true ? "Continue Stripe setup" : "Set up Stripe payouts", icon: .wallet, style: .dark) {
                    Task { if let url = await earnings.onboardingURL(api: services.api) { onboarding = PayoutSetup(url: url) } }
                }
            }
            .foregroundStyle(BountyColor.creamInk)
            .padding(16)
            .tintedPanel(BountyColor.cream, radius: BountyRadius.row)
        }
    }

    private func reload() async {
        async let marketplace: Void = earnings.refresh(api: services.api)
        async let usdc: Void = payments.refresh()
        _ = await (marketplace, usdc)
        if let api = services.api { trust = try? await api.request(.get, "me/trust") }
    }
}

extension Notification.Name {
    /// Posted when the app opens `bounty://wallet…` after Stripe Connect onboarding.
    static let payoutSetupReturned = Notification.Name("payoutSetupReturned")
}

/// One earning's job, rail, reference and status history (US-55).
struct TransactionDetailView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    let item: EarningItem
    @State private var timeline: [TimelineEntry] = []
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Amount", value: item.amountText)
                    LabeledContent("Status", value: item.statusText)
                    LabeledContent("Rail", value: item.railText)
                    if let reference = item.reference {
                        LabeledContent("Reference") {
                            if let url = item.referenceUrl.flatMap(URL.init(string:)) {
                                Link(reference, destination: url).font(.caption.monospaced())
                            } else {
                                Text(reference).font(.caption.monospaced()).textSelection(.enabled)
                            }
                        }
                    }
                    if let seconds = item.timeToPaidSeconds {
                        LabeledContent("Paid after approval", value: "in \(PayoutSpeed.text(seconds))")
                    }
                    LabeledContent("Updated", value: item.updatedAt.formatted(date: .abbreviated, time: .shortened))
                } header: {
                    Text(item.title)
                }
                Section {
                    MoneyTrailCard(jobId: item.jobId, refreshKey: item.status)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section("History") {
                    if timeline.isEmpty, message == nil { ProgressView() }
                    ForEach(timeline) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.label)
                            Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Earning")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task {
                guard let api = services.api else { return }
                do { timeline = try await api.request(.get, "jobs/\(item.jobId)/timeline") } catch { message = error.localizedDescription }
            }
        }
    }
}

/// The tax jar: tracks a share of this year's payouts to set aside for taxes. A budgeting aid only; the
/// money stays in the worker's payout account.
private struct TaxJarCard: View {
    let summary: EarningsSummary
    let onChange: (Int) -> Void

    private var percent: Int { summary.taxSetAside?.percent ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                StickerTile(sticker: .coins, background: BountyColor.cream, size: 44, stickerSize: 34, radius: 13)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tax jar").bountyType(.bodyStrong)
                    Text(percent == 0 ? "Track a share of each payout for taxes" : "\(percent)% of \((summary.yearToDatePaid ?? 0).formatted(.currency(code: "USD"))) paid this year")
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Menu {
                    ForEach([0, 10, 15, 20, 25, 30], id: \.self) { option in
                        Button(option == 0 ? "Off" : "\(option)%") { onChange(option) }
                    }
                } label: {
                    Text(percent == 0 ? "Set up" : "\(percent)%")
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.lavenderInk)
                }
            }
            if percent > 0 {
                Text((summary.taxSetAside?.amount ?? 0).formatted(.currency(code: "USD")))
                    .bountyType(.moneyM)
                    .foregroundStyle(BountyColor.creamInk)
                Text("Set aside so far. Bounty only tracks this; the money stays in your payout account. Self-employed workers usually owe 15\u{2013}30% of profit; check with a tax professional.")
                    .bountyType(.caption)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
        .foregroundStyle(BountyColor.inkPrimary)
        .padding(14)
        .borderedCard(radius: BountyRadius.row)
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
    EarningsView()
        .environment(AppServices())
        .environmentObject(WorkerPayments())
}

/// The worker's trust score and escrow limit: like a credit limit, it grows with rated work.
private struct TrustCard: View {
    let trust: WorkerTrustScore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Trust score", icon: .badgeCheck)
                    .bountyType(.bodyStrong)
                Spacer()
                Text(trust.score, format: .percent.precision(.fractionLength(0)))
                    .bountyType(.bodyStrong)
            }
            .foregroundStyle(BountyColor.inkPrimary)
            Meter(value: min(1, trust.openExposure / max(trust.exposureLimit, 1)))
            Text("Suggested escrow limit \(trust.exposureLimit.formatted(.currency(code: "USD"))), with \(trust.openExposure.formatted(.currency(code: "USD"))) in jobs right now. Well-rated jobs for different people raise it.")
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkSecondary)
        }
        .padding(16)
        .borderedCard(radius: BountyRadius.row)
    }
}
