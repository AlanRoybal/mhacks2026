import SwiftUI

/// 06 Home.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @Environment(ProfileStore.self) private var profileStore

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowYellow, height: 380), spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Good evening")
                        .bountyType(.subhead)
                        .foregroundStyle(BountyColor.inkSecondary)
                    Text(profileStore.profile.firstName)
                        .bountyType(.title)
                        .foregroundStyle(BountyColor.inkPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer()
                HStack(spacing: 8) {
                    IconButton(icon: .bell, label: "Notifications") { router.open(.notifications) }
                        .overlay(alignment: .topTrailing) {
                            if HomeNotification.unreadCount(router: router) > 0 {
                                Circle()
                                    .fill(BountyColor.coral)
                                    .frame(width: 10, height: 10)
                                    .overlay(Circle().stroke(BountyColor.canvas, lineWidth: 2))
                                    .offset(x: -2, y: 2)
                                    .allowsHitTesting(false)
                            }
                        }
                        .accessibilityValue("\(HomeNotification.unreadCount(router: router)) unread")
                    Button { router.open(.profile) } label: {
                        InitialsAvatar(initials: profileStore.profile.initials)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Your profile")
                    .accessibilityHint("View and edit your personal information")
                    .accessibilityIdentifier("profileButton")
                }
            }
            .entrance(.top)

            TwinStatusPill()
                .entrance(.top)

            if !router.offerDeclined {
                NewMatchCard(
                    expiry: router.offerExpiry,
                    onDecline: { withAnimation(Motion.enterRest) { router.offerDeclined = true } },
                    onView: { router.open(.offer) }
                )
                .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.96))))
                .entrance(.top)
            }

            SectionHeader(title: "Your jobs", trailing: "See all") { router.select(.jobs) }
                .entrance(.rest(0))

            Button { router.open(.jobDetail) } label: {
                HomeJobRow(job: SampleJobs.vintageDesk, detail: "Accepted · Tomorrow, 2 PM")
            }
            .buttonStyle(PressableStyle())
            .entrance(.rest(1))

            HomeJobRow(job: SampleJobs.poster, detail: "In review · releases in 1h 12m")
                .entrance(.rest(2))
        }
    }
}

/// Activity for the same sample jobs shown on Home and Jobs.
private struct HomeNotification: Identifiable {
    let id: String
    let title: String
    let message: String
    let actionLabel: String
    let icon: BountyIcon
    let route: AppRoute?

    @MainActor
    static func items(router: AppRouter) -> [HomeNotification] {
        var items: [HomeNotification] = []
        if !router.offerDeclined {
            items.append(HomeNotification(
                id: "coffee-offer", title: "Your twin found a match",
                message: "Sketch a coffee shop logo · $15 · 0.4 mi away",
                actionLabel: "View offer", icon: .sparkles, route: .offer
            ))
        }
        items.append(HomeNotification(
            id: "desk-accepted", title: "You’re booked",
            message: "Photograph a vintage desk · Tomorrow, 2 PM",
            actionLabel: "View job", icon: .briefcase, route: .jobDetail
        ))
        items.append(HomeNotification(
            id: "calculus-review", title: "Your work is in review",
            message: "Review a calculus worksheet · $35",
            actionLabel: "View jobs", icon: .shieldCheck, route: nil
        ))
        return items
    }

    @MainActor
    static func unreadCount(router: AppRouter) -> Int {
        items(router: router).filter { !router.readNotificationIDs.contains($0.id) }.count
    }
}

struct NotificationsView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowYellow, height: 300), spacing: 16) {
            NavRow(leadingAction: router.back) {
                Text("Notifications")
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
            } trailing: {
                EmptyView()
            }
            .entrance(.top)

            HStack {
                Text(HomeNotification.unreadCount(router: router) == 0
                     ? "You’re all caught up"
                     : "\(HomeNotification.unreadCount(router: router)) unread")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
                Spacer()
                Button("Mark all read") {
                    router.readNotificationIDs.formUnion(HomeNotification.items(router: router).map(\.id))
                }
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkPrimary)
                .disabled(HomeNotification.unreadCount(router: router) == 0)
                .opacity(HomeNotification.unreadCount(router: router) == 0 ? 0.4 : 1)
            }
            .entrance(.top)

            ForEach(Array(HomeNotification.items(router: router).enumerated()), id: \.element.id) { index, notification in
                notificationRow(notification)
                    .entrance(.rest(index))
            }
        }
    }

    private func notificationRow(_ notification: HomeNotification) -> some View {
        let isUnread = !router.readNotificationIDs.contains(notification.id)
        return Button {
            router.readNotificationIDs.insert(notification.id)
            if let route = notification.route {
                router.open(route)
            } else {
                router.jobsSegment = .working
                router.select(.jobs)
            }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                IconGlyph(icon: notification.icon, size: 24)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .frame(width: 44, height: 44)
                    .background(BountyColor.cream, in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(notification.title)
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                    Text(notification.message)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                    Text(notification.actionLabel)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkPrimary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isUnread {
                    Circle()
                        .fill(BountyColor.coral)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                }
            }
            .multilineTextAlignment(.leading)
            .padding(16)
            .borderedCard(radius: BountyRadius.row)
        }
        .buttonStyle(PressableStyle())
        .accessibilityValue(isUnread ? "Unread" : "Read")
    }
}

private struct TwinStatusPill: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(BountyColor.green)
                .frame(width: 10, height: 10)
                .background {
                    Circle()
                        .fill(BountyColor.green.opacity(0.35))
                        .scaleEffect(pulsing ? 2.2 : 1)
                        .opacity(pulsing ? 0 : 1)
                }
                .onAppear {
                    withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulsing = true }
                }
            Text("Your twin is searching")
                .bountyType(.subheadStrong)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("27 checked today")
                .bountyType(.footnote)
        }
        .foregroundStyle(BountyColor.lavenderInk)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .tintedPanel(BountyColor.lavenderSoft, radius: 22)
        .accessibilityElement(children: .combine)
    }
}

private struct NewMatchCard: View {
    let expiry: Date
    let onDecline: () -> Void
    let onView: () -> Void

    var body: some View {
        StackCard(tone: .cream, height: 244, bandTop: 174) {
            VStack(alignment: .leading, spacing: 6) {
                OfferCountdown(expiry: expiry) { remaining in
                    Chip(label: "New match · \(remaining) left", tone: .coral)
                }
                HStack {
                    Text("$15")
                        .bountyType(.moneyL)
                    Spacer()
                    StickerView(sticker: .coffee, size: 52)
                }
                Text("Sketch a coffee shop logo")
                    .bountyType(.bodyStrong)
                Text("0.4 mi · about 10 min · Due 6:00 PM")
                    .bountyType(.footnote)
                HStack(spacing: 10) {
                    PillButton(title: "Decline", style: .outline, action: onDecline)
                    PillButton(title: "View offer", action: onView)
                }
                .padding(.top, 4)
            }
            .foregroundStyle(BountyColor.creamInk)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .frame(maxWidth: .infinity, alignment: .leading)

        }
    }
}

struct HomeJobRow: View {
    let job: Job
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            StickerTile(sticker: job.sticker, background: job.tileColor, size: 44, stickerSize: 34, radius: 14)
            TitleSubtitle(title: job.title, subtitle: detail, titleType: .subheadStrong, subtitleType: .footnote)
                .multilineTextAlignment(.leading)
            Text("$\(job.pay)")
                .bountyType(.moneyM)
                .foregroundStyle(BountyColor.inkPrimary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
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
}
