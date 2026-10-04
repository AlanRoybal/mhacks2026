import SwiftUI

// MARK: - 09 Job detail — in progress

struct JobDetailView: View {
    @Environment(AppRouter.self) private var router

    private let requirements = [
        "Hand-drawn logo with a coffee cup",
        "Shop name “Blue Fern” is readable",
        "One-time code 7Q4K written on the page"
    ]

    var body: some View {
        BountyScreen {
            NavRow(leadingAction: router.back) {
                Chip(label: "In progress", tone: .lavender)
            } trailing: {
                IconButton(icon: .ellipsis, label: "More") {}
            }
            .entrance(.top)

            HStack(spacing: 14) {
                StickerTile(sticker: .coffee, background: BountyColor.cream, size: 64, stickerSize: 54, radius: 19)
                TitleSubtitle(title: "Sketch a coffee shop logo", subtitle: "$15 · Due today, 6:00 PM", titleType: .headline)
            }
            .entrance(.top)

            HStack(spacing: 12) {
                InitialsAvatar(initials: "MK", background: BountyColor.creamBand, foreground: BountyColor.creamInk)
                TitleSubtitle(title: "Maya · Blue Fern Coffee", subtitle: "★ 4.9 · 23 jobs posted")
                IconButton(icon: .mail, label: "Message Maya", size: 36, iconSize: 18) {}
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .borderedCard(radius: BountyRadius.row)
            .entrance(.top)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("What counts as done")
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Chip(label: "Locked", tone: .grey)
                }
                ForEach(requirements, id: \.self) { requirement in
                    HStack(spacing: 12) {
                        StatusBadge(status: .todo)
                        Text(requirement)
                            .bountyType(.subhead)
                            .foregroundStyle(BountyColor.inkPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)
                }
            }
            .padding(16)
            .borderedCard()
            .entrance(.rest(0))

            JobTimeline()
                .padding(16)
                .borderedCard()
                .entrance(.rest(1))

            HStack(spacing: 12) {
                StickerView(sticker: .shield, size: 40)
                Text("$15 is held safely. It releases when your proof passes review.")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.mintInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .tintedPanel(BountyColor.mint, radius: BountyRadius.row)
            .entrance(.rest(2))
        } bottom: {
            PillButton(title: "Start proof", icon: .camera) { router.open(.proofCapture) }
        }
    }
}

private struct JobTimeline: View {
    private struct Step: Identifiable {
        var id: String { title }
        let title: String
        let time: String
        let state: StepStatus
    }

    private let steps = [
        Step(title: "Funded", time: "2:01 PM", state: .done),
        Step(title: "Accepted", time: "2:03 PM", state: .done),
        Step(title: "Working", time: "Now", state: .active),
        Step(title: "Review", time: " ", state: .todo),
        Step(title: "Paid", time: " ", state: .todo)
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            ForEach(steps) { step in
                VStack(spacing: 5) {
                    Capsule()
                        .fill(color(for: step.state))
                        .frame(width: step.state == .active ? 34 : 14, height: 14)
                    Text(step.title)
                        .bountyType(.caption)
                        .foregroundStyle(step.state == .todo ? BountyColor.inkTertiary : BountyColor.inkPrimary)
                    Text(step.time)
                        .bountyType(.caption)
                        .foregroundStyle(BountyColor.inkTertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func color(for state: StepStatus) -> Color {
        switch state {
        case .done: BountyColor.green
        case .active: BountyColor.yellow
        case .todo: BountyColor.pill
        }
    }
}

// MARK: - 10 Proof capture

struct ProofCaptureView: View {
    @Environment(AppRouter.self) private var router
    @State private var flash = false
    @State private var codeFound = false

    var body: some View {
        BountyScreen(background: BountyColor.night, spacing: 10, scrolls: false) {
            NavRow(
                leadingIcon: .x,
                leadingLabel: "Close",
                leadingBackground: BountyColor.inkPill,
                leadingForeground: BountyColor.inkInverse,
                leadingAction: router.back
            ) {
                Chip(label: "After photo · 1 of 2", tone: .yellow)
            } trailing: {
                IconButton(icon: .zap, label: "Flash", background: BountyColor.inkPill, foreground: BountyColor.inkInverse) {}
            }
            .entrance(.top)

            Viewfinder(codeFound: codeFound)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(.white)
                        .opacity(flash ? 0.85 : 0)
                        .allowsHitTesting(false)
                }
                .entrance(.top)

            Text("Line the page up with the dotted outline. Photos from your library aren’t accepted.")
                .bountyType(.subhead)
                .foregroundStyle(BountyColor.inkInverse)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .entrance(.rest(0))
        } bottom: {
            HStack {
                StickerView(sticker: .poster, size: 36)
                    .frame(width: 52, height: 52)
                    .background(Color(hex: 0xFAFAF7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(BountyColor.inkInverse, lineWidth: 2)
                    }
                    .accessibilityLabel("Before photo")
                Spacer()
                Button(action: capture) {
                    Image("shutter")
                        .resizable()
                        .frame(width: 80, height: 80)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Take photo")
                Spacer()
                IconButton(
                    icon: .refresh,
                    label: "Switch camera",
                    size: 52,
                    background: BountyColor.inkPill,
                    foreground: BountyColor.inkInverse
                ) {}
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(900))
            withAnimation(Motion.press) { codeFound = true }
        }
    }

    private func capture() {
        withAnimation(.easeOut(duration: 0.08)) { flash = true }
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(.easeIn(duration: 0.25)) { flash = false }
            router.open(.proofCheck)
        }
    }
}

private struct Viewfinder: View {
    let codeFound: Bool

    var body: some View {
        ZStack {
            Color(hex: 0x5B4A3A)

            VStack(spacing: 0) {
                StickerView(sticker: .coffee, size: 140)
                    .padding(.top, 40)
                Text("BLUE FERN")
                    .bountyType(.headline)
                    .foregroundStyle(BountyColor.creamInk)
                    .padding(.top, 10)
                Text("7Q4K")
                    .bountyType(.title)
                    .foregroundStyle(BountyColor.red)
                    .padding(.top, 17)
                Spacer(minLength: 0)
            }
            .frame(width: 230, height: 300)
            .background(Color(hex: 0xFAFAF7), in: RoundedRectangle(cornerRadius: 4))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 10)
            .rotationEffect(.degrees(4))
            .offset(x: -10, y: 1)

            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(BountyColor.inkInverse, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .frame(width: 244, height: 312)
                .offset(y: -7)

            Image("frame-guides")
                .resizable()
                .frame(width: 301, height: 390)
        }
        .frame(height: 390)
        .overlay(alignment: .top) {
            HStack {
                ViewfinderPill(icon: .locate, iconColor: BountyColor.green, text: "Blue Fern Coffee · ±5 m")
                Spacer()
                ViewfinderPill(icon: .clock, iconColor: BountyColor.inkInverse, text: "2:14 PM")
            }
            .padding(14)
        }
        .overlay(alignment: .bottom) {
            if codeFound {
                HStack(spacing: 6) {
                    IconGlyph(icon: .check, size: 16, weight: .bold)
                    Text("Code 7Q4K found")
                        .bountyType(.subheadStrong)
                }
                .foregroundStyle(BountyColor.inkPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(BountyColor.green, in: Capsule())
                .padding(.bottom, 20)
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Camera viewfinder")
    }
}

private struct ViewfinderPill: View {
    let icon: BountyIcon
    let iconColor: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            IconGlyph(icon: icon, size: 14)
                .foregroundStyle(iconColor)
            Text(text)
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkInverse)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(BountyColor.inkPrimary, in: Capsule())
    }
}

// MARK: - 11 AI verification

struct ProofCheckView: View {
    @Environment(AppRouter.self) private var router

    private let checks = [
        ("Hand-drawn coffee cup logo", "Cup and steam lines found", "97%"),
        ("“Blue Fern” is readable", "Read as BLUE FERN", "91%"),
        ("Code 7Q4K is on the page", "Matches your code. Taken live at 2:14 PM.", "99%")
    ]

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowMint, height: 420), spacing: 10) {
            NavRow(leadingAction: router.back) {
                Text("Proof check")
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
            } trailing: {
                EmptyView()
            }
            .entrance(.top)

            Image("proof-card")
                .resizable()
                .frame(height: 150)
                .background(alignment: .top) {
                    RoundedRectangle(cornerRadius: BountyRadius.stackCard, style: .continuous)
                        .fill(BountyColor.mintBack)
                        .padding(.horizontal, 12)
                        .offset(y: 12)
                }
                .padding(.bottom, 12)
                .accessibilityHidden(true)
                .entrance(.top)

            ScreenTitle(title: "Looks good!") {
                Chip(label: "3 of 3 passed", tone: .mint)
            }
            .entrance(.top)

            Text("AI compared your photo to what Maya asked for. She makes the final call.")
                .bountyType(.body)
                .foregroundStyle(BountyColor.inkSecondary)
                .entrance(.rest(0))

            VStack(spacing: 4) {
                ForEach(checks, id: \.0) { check in
                    HStack(spacing: 12) {
                        StatusBadge(status: .done)
                        TitleSubtitle(title: check.0, subtitle: check.1, titleType: .subheadStrong, subtitleType: .subhead)
                        Text(check.2)
                            .bountyType(.subheadStrong)
                            .foregroundStyle(BountyColor.greenInk)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .borderedCard()
            .entrance(.rest(1))

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    IconGlyph(icon: .hourglass, size: 18)
                    Text("Maya has 2 hours to review")
                        .bountyType(.bodyStrong)
                }
                Meter(value: 0.12, fill: BountyColor.yellow, track: BountyColor.creamBand)
                Text("No answer by 4:14 PM? Your $15 is released automatically.")
                    .bountyType(.footnote)
            }
            .foregroundStyle(BountyColor.creamInk)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .tintedPanel(BountyColor.cream)
            .entrance(.rest(2))
        } bottom: {
            PillButton(title: "Done") { router.finish(on: .home) }
        }
    }
}

#Preview("Job detail") {
    JobDetailView()
        .environment(AppRouter())
}

#Preview("Proof capture") {
    ProofCaptureView()
        .environment(AppRouter())
}

#Preview("Proof check") {
    ProofCheckView()
        .environment(AppRouter())
}
