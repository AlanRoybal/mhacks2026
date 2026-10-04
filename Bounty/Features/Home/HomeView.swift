import SwiftUI

/// 06 Home.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var services
    @Environment(MarketplaceStore.self) private var marketplace
    @EnvironmentObject private var workerPayments: WorkerPayments
    @State private var name: String?
    @State private var showsSettings = false
    @State private var unreadCount = 0
    @State private var readiness: TwinSettings.Readiness?

    private var greeting: String {
        switch Calendar.current.component(.hour, from: .now) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        default: "Good evening"
        }
    }

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowYellow, height: 380), spacing: 18, alwaysBounces: true) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(greeting)
                        .bountyType(.subhead)
                        .foregroundStyle(BountyColor.inkSecondary)
                    Text(name ?? (services.api == nil ? "Alan" : " "))
                        .bountyType(.title)
                        .foregroundStyle(BountyColor.inkPrimary)
                }
                Spacer()
                HStack(spacing: 8) {
                    IconButton(icon: .bell, label: unreadCount > 0 ? "Notifications, \(unreadCount) unread" : "Notifications") {
                        router.open(.notifications)
                    }
                    .overlay(alignment: .topTrailing) {
                        if unreadCount > 0 {
                            Circle()
                                .fill(BountyColor.red)
                                .frame(width: 10, height: 10)
                                .overlay(Circle().strokeBorder(BountyColor.canvas, lineWidth: 2))
                                .offset(x: -6, y: 6)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    Button { showsSettings = true } label: {
                        InitialsAvatar(initials: JobDetailView.initials(name ?? (services.api == nil ? "Alan R" : "?")))
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Account")
                }
            }
            .entrance(.top)

            TwinStatusPill(readiness: readiness)
                .entrance(.top)

            if let offer = marketplace.currentOffer, let job = marketplace.offeredJob {
                NewMatchCard(
                    job: job.displayJob,
                    expiry: offer.expiresAt ?? .now,
                    onDecline: { Task { _ = await marketplace.respond(api: services.api, accept: false) } },
                    onView: { router.open(.offer) }
                )
                .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.96))))
                .entrance(.top)
            } else if services.api == nil && !router.offerDeclined {
                NewMatchCard(
                    job: SampleJobs.coffeeLogo,
                    expiry: router.offerExpiry,
                    onDecline: { withAnimation(Motion.enterRest) { router.offerDeclined = true } },
                    onView: { router.open(.offer) }
                )
                .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.96))))
                .entrance(.top)
            }

            SectionHeader(title: "Your jobs", trailing: "See all") { router.select(.jobs) }
                .entrance(.rest(0))

            if marketplace.workingJobs.isEmpty && workerPayments.jobs.isEmpty {
                Text("No assigned jobs yet.").bountyType(.footnote)
            }
            ForEach((marketplace.workingJobs.map(\.displayJob) + workerPayments.jobs).prefix(3)) { job in
                Button {
                    // Marketplace jobs open their own screen; checkout-only jobs live under Jobs.
                    if marketplace.workingJobs.contains(where: { $0.id == job.id }) {
                        router.open(.jobDetail, workerJob: job.id)
                    } else {
                        router.select(.jobs)
                    }
                } label: {
                    HomeJobRow(job: job, detail: "\(job.status.rawValue) · \(job.deadline)")
                }
                .buttonStyle(PressableStyle())
            }
        }
        .sheet(isPresented: $showsSettings) { SettingsView() }
        // Loads on launch and whenever a screen above Home (e.g. Notifications) closes; pulling down reloads.
        .task(id: router.route == nil) {
            guard router.route == nil else { return }
            await reload(includingJobs: false)
        }
        .refreshable { await reload(includingJobs: true) }
    }

    /// Name, twin status and the bell's dot. The offer and job stores also refresh when the app becomes
    /// active (RootTabView), so only a pull reloads them here.
    private func reload(includingJobs: Bool) async {
        guard let api = services.api else { return }
        async let me: MeProfile? = try? api.request(.get, "me")
        async let twin: TwinSettings? = try? api.request(.get, "twin")
        async let inbox: InboxPage? = try? api.request(.get, "me/notifications")
        if includingJobs {
            await marketplace.refresh(api: api)
            await workerPayments.refresh()
        }
        let (profile, settings, page) = await (me, twin, inbox)
        if let profile { name = profile.displayName }
        if let settings { readiness = settings.readiness }
        if let page { withAnimation(Motion.press) { unreadCount = page.unreadCount } }
    }
}

private struct TwinStatusPill: View {
    @Environment(AppRouter.self) private var router
    let readiness: TwinSettings.Readiness?
    @State private var pulsing = false

    private var isReady: Bool { readiness?.ready ?? true }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(isReady ? BountyColor.green : BountyColor.coral)
                .frame(width: 10, height: 10)
                .background {
                    Circle()
                        .fill((isReady ? BountyColor.green : BountyColor.coral).opacity(0.35))
                        .scaleEffect(pulsing ? 2.2 : 1)
                        .opacity(pulsing ? 0 : 1)
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulsing = true }
                }
            Text(isReady ? "Your twin is searching" : "Your twin isn\u{2019}t searching yet")
                .bountyType(.subheadStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let missing = readiness?.missing, !missing.isEmpty {
                Button("Fix") { router.select(.twin) }
                    .bountyType(.footnote)
            }
        }
        .foregroundStyle(BountyColor.lavenderInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .tintedPanel(BountyColor.lavenderSoft, radius: 22)
        .accessibilityElement(children: .combine)
    }
}

private struct NewMatchCard: View {
    let job: Job
    let expiry: Date
    let onDecline: () -> Void
    let onView: () -> Void

    var body: some View {
        StackCard(tone: .cream, height: 292, bandTop: 204.4) {
            VStack(alignment: .leading, spacing: 6) {
                OfferCountdown(expiry: expiry) { remaining in
                    Chip(label: "New match · \(remaining) left", tone: .coral)
                }
                Text(job.displayPay)
                    .bountyType(.moneyXL)
                Text(job.title)
                    .bountyType(.headline)
                Text("\(job.location) · Due \(job.deadline)")
                    .bountyType(.subhead)
                HStack(spacing: 10) {
                    PillButton(title: "Decline", style: .outline, action: onDecline)
                    PillButton(title: "View offer", action: onView)
                }
                .padding(.top, 8)
            }
            .foregroundStyle(BountyColor.creamInk)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .topTrailing) {
                StickerView(sticker: job.sticker, size: 100)
                    .padding(.top, 14)
                    .padding(.trailing, 17)
            }
        }
    }
}

struct HomeJobRow: View {
    let job: Job
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            StickerTile(sticker: job.sticker, background: job.tileColor)
            TitleSubtitle(title: job.title, subtitle: detail)
                .multilineTextAlignment(.leading)
            Text(job.displayPay)
                .bountyType(.moneyM)
                .foregroundStyle(BountyColor.inkPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .borderedCard(radius: BountyRadius.row)
    }
}

/// Re-renders every second with the time left before `expiry`, formatted m:ss.
struct OfferCountdown<Label: View>: View {
    let expiry: Date
    @ViewBuilder let label: (String) -> Label

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let seconds = max(0, Int(expiry.timeIntervalSince(context.date).rounded(.up)))
            label(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
    }
}

#Preview {
    HomeView()
        .environment(AppRouter())
        .environment(AppServices())
        .environment(MarketplaceStore())
        .environmentObject(WorkerPayments())
}
