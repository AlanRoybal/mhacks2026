import SwiftUI

/// 06 Home.
struct HomeView: View {
    @Environment(AppRouter.self) private var router
    @EnvironmentObject private var workerPayments: WorkerPayments

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowYellow, height: 380), spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Good evening")
                        .bountyType(.subhead)
                        .foregroundStyle(BountyColor.inkSecondary)
                    Text("Alan")
                        .bountyType(.title)
                        .foregroundStyle(BountyColor.inkPrimary)
                }
                Spacer()
                HStack(spacing: 8) {
                    IconButton(icon: .bell, label: "Notifications") { router.open(.lockScreenOffer) }
                    InitialsAvatar(initials: "AR")
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

            if workerPayments.jobs.isEmpty {
                Text("No assigned jobs yet.").bountyType(.footnote)
            }
            ForEach(workerPayments.jobs.prefix(3)) { job in
                Button { router.select(.jobs) } label: {
                    HomeJobRow(job: job, detail: "\(job.status.rawValue) · \(job.deadline)")
                }
                .buttonStyle(PressableStyle())
            }
        }
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
        .padding(.vertical, 10)
        .tintedPanel(BountyColor.lavenderSoft, radius: 22)
        .accessibilityElement(children: .combine)
    }
}

private struct NewMatchCard: View {
    let expiry: Date
    let onDecline: () -> Void
    let onView: () -> Void

    var body: some View {
        StackCard(tone: .cream, height: 292, bandTop: 204.4) {
            VStack(alignment: .leading, spacing: 6) {
                OfferCountdown(expiry: expiry) { remaining in
                    Chip(label: "New match · \(remaining) left", tone: .coral)
                }
                Text("$15")
                    .bountyType(.moneyXL)
                Text("Sketch a coffee shop logo")
                    .bountyType(.headline)
                Text("0.4 mi · about 10 min · Due 6:00 PM")
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
                StickerView(sticker: .coffee, size: 100)
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
        .environmentObject(WorkerPayments())
}
