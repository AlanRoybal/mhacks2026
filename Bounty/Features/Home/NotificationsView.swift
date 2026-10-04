import SwiftUI
import TwinKit

/// Notifications page (the bell on Home): every alert the backend sent, newest first (`GET /me/notifications`).
/// Opening it marks everything read. Tapping a row goes where tapping that push would.
struct NotificationsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var services
    @Environment(MarketplaceStore.self) private var marketplace
    @State private var items: [InboxNotification]?
    @State private var loadError: String?

    var body: some View {
        BountyScreen(spacing: 16, alwaysBounces: true) {
            NavRow(leadingAction: router.back) {
                Text("Notifications").bountyType(.bodyStrong)
            } trailing: {
                EmptyView()
            }
            .entrance(.top)

            content
                .entrance(.rest(0))
        }
        .refreshable { await load() }
        .task {
            await load()
            await markRead()
        }
    }

    @ViewBuilder
    private var content: some View {
        if let items, !items.isEmpty {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button { open(item) } label: { NotificationRow(item: item) }
                        .buttonStyle(PressableStyle())
                    if item.id != items.last?.id {
                        BountyColor.divider.frame(height: 1).padding(.leading, 64)
                    }
                }
            }
            .padding(.horizontal, 14)
            .borderedCard()
        } else if let loadError, items == nil {
            VStack(spacing: 12) {
                Text("Couldn\u{2019}t load notifications")
                    .bountyType(.headline)
                    .foregroundStyle(BountyColor.inkPrimary)
                Text(loadError)
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
                PillButton(title: "Try again", icon: .refresh, style: .secondary) { Task { await load() } }
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else if items == nil {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading notifications\u{2026}")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
        } else {
            VStack(spacing: 12) {
                IconGlyph(icon: .bell, size: 30)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .frame(width: 72, height: 72)
                    .background(BountyColor.pill, in: Circle())
                Text("No notifications yet")
                    .bountyType(.headline)
                    .foregroundStyle(BountyColor.inkPrimary)
                Text("New job matches, proof reviews and payments will show up here.")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 48)
        }
    }

    private func load() async {
        guard let api = services.api else {
            items = []
            return
        }
        do {
            let page: InboxPage = try await api.request(.get, "me/notifications")
            items = page.items
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func markRead() async {
        guard let api = services.api, items?.contains(where: { !$0.read }) == true else { return }
        try? await api.send(.post, "me/notifications/read")
    }

    /// Same destinations as tapping the push itself (PushNotificationManager → RootTabView).
    private func open(_ item: InboxNotification) {
        if item.type == "offer", let offerId = item.offerId, marketplace.currentOffer?.id == offerId {
            router.open(.offer)
        } else if PosterPush.posterTypes.contains(item.type) || PosterPush.sharedTypes.contains(item.type) {
            let defaults = UserDefaults.standard
            defaults.set(PushRoute.postedJobDestination, forKey: PushRoute.destinationKey)
            defaults.set(item.type, forKey: PushRoute.actionKey)
            defaults.set(item.jobId, forKey: PushRoute.jobIDKey)
            NotificationCenter.default.post(name: .pushRouteChanged, object: item.jobId)
        } else if marketplace.workingJobs.contains(where: { $0.id == item.jobId }) {
            router.open(.jobDetail, workerJob: item.jobId)
        } else {
            router.reset(to: .jobs)
        }
    }
}

private struct NotificationRow: View {
    let item: InboxNotification

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            IconGlyph(icon: style.icon, size: 20)
                .foregroundStyle(BountyColor.inkPrimary)
                .frame(width: 40, height: 40)
                .background(style.tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkTertiary)
                }
                Text(item.body)
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .multilineTextAlignment(.leading)
            Circle()
                .fill(item.read ? Color.clear : BountyColor.lavender)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.read ? "" : "Unread")
    }

    private var style: (icon: BountyIcon, tint: Color) {
        switch item.type {
        case "offer": (.sparkles, BountyColor.yellow)
        case "offer_closed", "job_canceled", "worker_withdrew", "no_match_yet": (.hourglass, BountyColor.pill)
        case "offer_accepted": (.userRound, BountyColor.lavenderSoft)
        case "proof_ready", "proof_needs_decision", "proof_passed", "proof_escalated": (.shieldCheck, BountyColor.mint)
        case "proof_failed", "work_rejected": (.camera, BountyColor.cream)
        case "disputed", "resolved": (.flag, BountyColor.lavenderSoft)
        case "deadline_missed": (.clock, BountyColor.cream)
        case "paid", "refunded", "unmatched_refund": (.wallet, BountyColor.mint)
        default: (.bell, BountyColor.sky)
        }
    }
}

struct InboxNotification: Decodable, Identifiable, Sendable {
    let id: String
    let type: String
    let title: String
    let body: String
    let jobId: String
    let offerId: String?
    let createdAt: Date
    let read: Bool
}

struct InboxPage: Decodable, Sendable {
    let items: [InboxNotification]
    let unreadCount: Int
}

#Preview("Notifications") {
    NotificationsView()
        .environment(AppRouter())
        .environment(AppServices())
        .environment(MarketplaceStore())
}
