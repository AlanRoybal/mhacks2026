import LocalAuthentication
import SwiftUI

/// "Accept asks for Face ID." Falls back to accepting when the device has no biometrics set up.
@MainActor
enum AcceptGate {
    static func confirm() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Accept this job")
        } catch {
            return false
        }
    }
}

// MARK: - 07 Push offer (lock screen)

struct LockScreenOfferView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        BountyScreen(
            background: BountyColor.lavender,
            glow: ScreenGlow(
                colors: [BountyColor.lavenderBack, BountyColor.lavender, Color(hex: 0xC9C2FF, opacity: 0)],
                height: 852
            ),
            spacing: 6
        ) {
            TimelineView(.everyMinute) { context in
                VStack(spacing: 6) {
                    IconGlyph(icon: .lock, size: 22)
                    Text(context.date, format: .dateTime.weekday(.wide).month(.wide).day())
                        .bountyType(.headline)
                    Text(context.date.formatted(Date.VerbatimFormatStyle(format: "\(hour: .defaultDigits(clock: .twelveHour, hourCycle: .oneBased)):\(minute: .twoDigits)", timeZone: .current, calendar: .current)))
                        .bountyType(.money(size: 96, lineHeight: 104))
                }
                .foregroundStyle(BountyColor.inkInverse)
                .frame(maxWidth: .infinity)
            }
            .entrance(.top)

            Color.clear
                .frame(height: 150)

            VStack(spacing: 6) {
                OfferNotification()
                    .entrance(.top)
                NotificationActions(
                    onAccept: {
                        Task {
                            if await AcceptGate.confirm() { router.open(.jobDetail) }
                        }
                    },
                    onDecline: {
                        router.offerDeclined = true
                        router.finish(on: .home)
                    }
                )
                .entrance(.rest(0))

                Text("Accept asks for Face ID. The first person to accept gets the job.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkInverse)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                    .entrance(.rest(1))
            }
        } bottom: {
            HStack {
                lockButton(.zap, label: "Flashlight")
                Spacer()
                lockButton(.camera, label: "Camera")
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 26)
        }
    }

    private func lockButton(_ icon: BountyIcon, label: String) -> some View {
        IconGlyph(icon: icon, size: 22)
            .foregroundStyle(BountyColor.inkInverse)
            .frame(width: 50, height: 50)
            .background(BountyColor.inkPrimary.opacity(0.85), in: Circle())
            .accessibilityLabel(label)
    }
}

private struct OfferNotification: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconGlyph(icon: .sparkles, size: 22)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .frame(width: 38, height: 38)
                    .background(BountyColor.yellow, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                Text("BOUNTY")
                    .bountyType(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("now")
                    .bountyType(.footnote)
            }
            .foregroundStyle(BountyColor.inkSecondary)

            Text("New match · $15")
                .bountyType(.bodyStrong)
            Text("Sketch a coffee shop logo · 0.4 mi · about 10 min. Your twin matched it to your logo invoices.")
                .bountyType(.subhead)
        }
        .foregroundStyle(BountyColor.inkPrimary)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BountyColor.canvas, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
        .accessibilityElement(children: .combine)
    }
}

private struct NotificationActions: View {
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            actionRow("Accept", icon: .scanFace, color: BountyColor.inkPrimary, action: onAccept)
            BountyColor.divider.frame(height: 1)
            actionRow("Decline", icon: .x, color: BountyColor.red, action: onDecline)
        }
        .frame(width: 260)
        .background(BountyColor.canvas, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
    }

    private func actionRow(_ title: String, icon: BountyIcon, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .bountyType(.bodyStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                IconGlyph(icon: icon, size: 22)
            }
            .foregroundStyle(color)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 08 Offer

struct OfferView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowCream, height: 520)) {
            NavRow(leadingIcon: .x, leadingLabel: "Close", leadingAction: router.back) {
                OfferCountdown(expiry: router.offerExpiry) { remaining in
                    Chip(label: "Expires in \(remaining)", tone: .coral)
                }
            } trailing: {
                IconButton(icon: .ellipsis, label: "More") {}
            }
            .entrance(.top)

            VStack(spacing: 2) {
                Text("Your twin found you")
                    .bountyType(.subheadStrong)
                    .foregroundStyle(BountyColor.creamInk)
                Text("$15")
                    .bountyType(.money(size: 88, lineHeight: 92))
                    .foregroundStyle(BountyColor.inkPrimary)
                Text("≈ $90/hr · about 10 min")
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .entrance(.top)

            Text("Sketch a coffee shop logo")
                .bountyType(.title)
                .foregroundStyle(BountyColor.inkPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .entrance(.top)

            Image("map-art")
                .resizable()
                .frame(height: 130)
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 6) {
                        IconGlyph(icon: .navigation, size: 14)
                        Text("0.4 mi · 8 min walk · Blue Fern Coffee")
                            .bountyType(.footnote)
                    }
                    .foregroundStyle(BountyColor.inkPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(BountyColor.canvas, in: Capsule())
                    .padding(12)
                }
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityElement(children: .combine)
                .entrance(.rest(0))

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    IconGlyph(icon: .sparkles, size: 18)
                    Text("Why your twin picked this")
                        .bountyType(.bodyStrong)
                }
                Text("You sent 3 logo invoices this year (Gmail) and list brand design on LinkedIn. You’re free until 7 PM.")
                    .bountyType(.subhead)
            }
            .foregroundStyle(BountyColor.lavenderInk)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tintedPanel(BountyColor.lavenderSoft)
            .entrance(.rest(1))

            VStack(alignment: .leading, spacing: 8) {
                FieldLabel(text: "Proof you’ll submit")
                FlowLayout(spacing: 8) {
                    Chip(label: "Photo of the sketch", tone: .cream)
                    Chip(label: "Code on the page", tone: .cream)
                    Chip(label: "Shop name readable", tone: .cream)
                }
            }
            .entrance(.rest(2))
        } bottom: {
            HStack(spacing: 12) {
                PillButton(title: "Decline", style: .secondary) {
                    router.offerDeclined = true
                    router.finish(on: .home)
                }
                PillButton(title: "Accept", icon: .scanFace) {
                    Task {
                        if await AcceptGate.confirm() { router.open(.jobDetail) }
                    }
                }
            }
        }
    }
}

/// Wraps children onto new lines, like the chip rows in the design.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row {
        var indices: [Int] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let proposedWidth = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if proposedWidth > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row(y: current.y + current.height + spacing)
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

#Preview("Offer") {
    OfferView()
        .environment(AppRouter())
}

#Preview("Lock screen") {
    LockScreenOfferView()
        .environment(AppRouter())
}
