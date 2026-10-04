import AuthenticationServices
import SwiftUI
import TwinKit

/// 01 Welcome → 02 Profile import → 03 Building your twin → 05 Availability.
/// Finishing lands on 04 Twin review in the Twin tab.
struct OnboardingView: View {
    let onComplete: @MainActor () -> Void

    @State private var step = Step.welcome
    @State private var transition = ScreenTransition()

    enum Step {
        case welcome
        case profileImport
        case building
        case availability
    }

    var body: some View {
        Group {
            switch step {
            case .welcome:
                WelcomeView { go(to: .profileImport) }
            case .profileImport:
                ProfileImportView(onBack: { go(to: .welcome) }, onContinue: { go(to: .building) })
            case .building:
                BuildingTwinView(onCancel: { go(to: .profileImport) }, onContinue: { go(to: .availability) })
            case .availability:
                AvailabilityView(onBack: { go(to: .profileImport) }, onContinue: { transition.perform(onComplete) })
            }
        }
        .id(step)
        .environment(\.screenExiting, transition.isExiting)
        .preferredColorScheme(.light)
        #if DEBUG
        .onAppear {
            if let debugStep = DebugLaunch.onboardingStep { step = debugStep }
        }
        #endif
    }

    private func go(to next: Step) {
        transition.perform { step = next }
    }
}

// MARK: - 01 Welcome

private struct WelcomeView: View {
    @Environment(AppServices.self) private var services
    let onContinue: () -> Void

    @State private var isSigningIn = false
    @State private var signInError: String?

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowLavender, height: 460), spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(BountyColor.yellow)
                    .frame(width: 22, height: 22)
                Text("bounty")
                    .bountyType(.headline)
                    .foregroundStyle(BountyColor.inkPrimary)
            }
            .padding(.top, 8)
            .accessibilityElement(children: .combine)
            .entrance(.top)

            StackCard(
                tone: StackTone(
                    front: BountyColor.lavenderBand,
                    back: BountyColor.lavenderInk,
                    band: BountyColor.lavenderBack
                ),
                height: 260,
                bandTop: 162
            ) {
                ZStack(alignment: .topLeading) {
                    StickerView(sticker: .twin, size: 140)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 26)
                    VStack(alignment: .leading, spacing: 10) {
                        Chip(label: "Your digital twin", tone: .dark)
                        Text("Finds paid jobs that fit you")
                            .bountyType(.headline)
                            .foregroundStyle(BountyColor.inkPrimary)
                    }
                    .padding(.leading, 20)
                    .padding(.top, 174)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: BountyRadius.stackCard, style: .continuous)
                    .strokeBorder(BountyColor.lavenderInk, lineWidth: 1.5)
                    .padding(.bottom, 12)
                    .allowsHitTesting(false)
            }
            .entrance(.top)

            VStack(spacing: 12) {
                Text("Meet your work twin")
                    .bountyType(.display)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .entrance(.rest(0))
                Text("It learns your skills, finds paid jobs nearby, and you just tap accept.")
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .entrance(.rest(1))
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
        } bottom: {
            VStack(spacing: 12) {
                PillButton(title: isSigningIn ? "Connecting…" : "Continue with LinkedIn", icon: .linkedin, style: .dark) {
                    signInWithLinkedIn()
                }
                .disabled(isSigningIn)
                PillButton(title: "Continue with Apple", icon: .apple, style: .secondary, action: onContinue)
                Text(signInError ?? "By continuing you agree to the Terms and Privacy Policy.")
                    .bountyType(.footnote)
                    .foregroundStyle(signInError == nil ? BountyColor.inkTertiary : BountyColor.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func signInWithLinkedIn() {
        guard let linkedIn = services.linkedIn else {
            // No backend configured (local builds): carry on with the demo profile.
            onContinue()
            return
        }
        isSigningIn = true
        signInError = nil
        Task {
            defer { isSigningIn = false }
            do {
                let response = try await linkedIn.signIn(presentationContextProvider: PresentationAnchor.shared)
                try await services.session.adopt(response)
                onContinue()
            } catch LinkedInOIDCError.cancelled {
                return
            } catch {
                signInError = error.localizedDescription
            }
        }
    }
}

@MainActor
private final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

// MARK: - 02 Profile import

private struct ProfileImportView: View {
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var addedLinkedIn = false
    @State private var addedCalendar = false

    var body: some View {
        BountyScreen {
            NavRow(leadingAction: onBack) {
                ProgressDots(total: 4, current: 1)
            } trailing: {
                StepLabel(text: "1 of 4")
            }
            .entrance(.top)

            Text("Teach your twin")
                .bountyType(.display)
                .foregroundStyle(BountyColor.inkPrimary)
                .entrance(.top)

            Text("Add what you’ve done. Your twin keeps the skills it finds, not your files.")
                .bountyType(.body)
                .foregroundStyle(BountyColor.inkSecondary)
                .entrance(.top)

            VStack(spacing: 12) {
                SourceRow(title: "Gmail", detail: "Read-only · sent mail", isAdded: true) {
                    StickerTile(sticker: .mail, background: BountyColor.sky)
                } onAdd: {}
                SourceRow(title: "LinkedIn profile PDF", detail: "Profile → Save to PDF", isAdded: addedLinkedIn) {
                    IconGlyph(icon: .linkedin, size: 24)
                        .foregroundStyle(BountyColor.lavenderInk)
                        .frame(width: 52, height: 52)
                        .background(BountyColor.lavenderSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } onAdd: {
                    withAnimation(Motion.press) { addedLinkedIn = true }
                }
                SourceRow(title: "Calendar", detail: "Free/busy, stays on device", isAdded: addedCalendar) {
                    StickerTile(sticker: .calendar, background: BountyColor.cream)
                } onAdd: {
                    withAnimation(Motion.press) { addedCalendar = true }
                }
            }
            .entrance(.rest(0))

            HStack(alignment: .top, spacing: 10) {
                IconGlyph(icon: .lock, size: 18)
                    .foregroundStyle(BountyColor.lavenderInk)
                Text("LinkedIn sign-in only shares your name and photo. The profile PDF adds your experience.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.lavenderInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(14)
            .tintedPanel(BountyColor.lavenderSoft, radius: 18)
            .entrance(.rest(1))
        } bottom: {
            PillButton(title: "Build my twin", icon: .sparkles, action: onContinue)
        }
    }
}

private struct SourceRow<Tile: View>: View {
    let title: String
    let detail: String
    let isAdded: Bool
    @ViewBuilder let tile: Tile
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            tile
            TitleSubtitle(title: title, subtitle: detail)
            if isAdded {
                Chip(label: "Connected", tone: .mint)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else {
                IconButton(icon: .plus, label: "Add \(title)", size: 36, iconSize: 18, action: onAdd)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .padding(14)
        .borderedCard(radius: BountyRadius.row)
    }
}

private struct StepLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .bountyType(.footnote)
            .foregroundStyle(BountyColor.inkSecondary)
    }
}

// MARK: - 03 Building your twin

private struct BuildingTwinView: View {
    let onCancel: () -> Void
    let onContinue: () -> Void

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowLavender, height: 460), spacing: 10) {
            NavRow(leadingIcon: .x, leadingLabel: "Cancel", leadingAction: onCancel) {
                ProgressDots(total: 4, current: 2)
            } trailing: {
                StepLabel(text: "2 of 4")
            }
            .entrance(.top)

            StackCard(tone: .lavender, height: 200, bandTop: 124) {
                ZStack(alignment: .topLeading) {
                    StickerView(sticker: .twin, size: 130)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 18)
                    Chip(label: "Reading 3 sources", tone: .dark)
                        .padding(.leading, 20)
                        .padding(.top, 158)
                }
            }
            .entrance(.top)

            Text("Building your twin…")
                .bountyType(.display)
                .foregroundStyle(BountyColor.inkPrimary)
                .entrance(.rest(0))

            VStack(spacing: 4) {
                BuildRow(status: .done, title: "Read LinkedIn PDF", detail: "Freelance designer · 2 yrs", trailing: "0:06")
                BuildRow(status: .active, title: "Scanning sent Gmail", detail: "Logo invoices, tutoring threads", trailing: "64%", progress: 0.64)
                BuildRow(status: .todo, title: "Checking your calendar", detail: "Free/busy blocks only")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .borderedCard()
            .entrance(.rest(1))
        } bottom: {
            PillButton(title: "Keep going in the background", style: .secondary, action: onContinue)
        }
        .task {
            // Auto-advance: moves on by itself after 2.5 s.
            try? await Task.sleep(for: Motion.autoAdvance)
            guard !Task.isCancelled else { return }
            onContinue()
        }
    }
}

private struct BuildRow: View {
    let status: StepStatus
    let title: String
    let detail: String
    var trailing: String?
    var progress: Double?

    var body: some View {
        HStack(spacing: 12) {
            StatusBadge(status: status)
            VStack(alignment: .leading, spacing: 2) {
                TitleSubtitle(title: title, subtitle: detail)
                if let progress {
                    Meter(value: progress, fill: BountyColor.yellow)
                }
            }
            if let trailing {
                Text(trailing)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
        .padding(.vertical, 10)
    }
}

// MARK: - 05 Availability & preferences

private struct AvailabilityView: View {
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var freeSlots: Set<Int> = [2, 4, 5, 6, 7, 9, 11, 12, 14, 15, 16, 17, 18, 19]
    @State private var minimumPay = 15.0
    @State private var radius = 3.0
    @State private var workMode = WorkMode.both
    @State private var hidden = ["Pet sitting", "Moving"]
    @State private var quietHours = true

    enum WorkMode: Hashable {
        case remote, inPerson, both
    }

    private let days = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        BountyScreen {
            NavRow(leadingAction: onBack) {
                ProgressDots(total: 4, current: 3)
            } trailing: {
                StepLabel(text: "4 of 4")
            }
            .entrance(.top)

            Text("When & where you work")
                .bountyType(.title)
                .foregroundStyle(BountyColor.inkPrimary)
                .entrance(.top)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    IconGlyph(icon: .calendar, size: 20)
                    Text("Free time from your calendar")
                        .bountyType(.bodyStrong)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Edit")
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.lavenderInk)
                }
                .foregroundStyle(BountyColor.inkPrimary)

                HStack(alignment: .top) {
                    ForEach(days.indices, id: \.self) { day in
                        VStack(spacing: 4) {
                            Text(days[day])
                                .bountyType(.caption)
                                .foregroundStyle(BountyColor.inkSecondary)
                            ForEach(0..<3, id: \.self) { block in
                                let slot = day * 3 + block
                                Button {
                                    withAnimation(Motion.pressTint) { toggle(slot) }
                                } label: {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(freeSlots.contains(slot) ? BountyColor.green : BountyColor.pill)
                                        .frame(width: 38, height: 18)
                                }
                                .buttonStyle(PressableStyle())
                                .accessibilityLabel("\(days[day]) block \(block + 1)")
                                .accessibilityValue(freeSlots.contains(slot) ? "Free" : "Busy")
                            }
                        }
                        if day < days.count - 1 { Spacer(minLength: 0) }
                    }
                }

                Text("Mornings · Afternoons · Evenings. Only free/busy leaves your phone.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            .padding(16)
            .borderedCard()
            .entrance(.top)

            VStack(alignment: .leading, spacing: 14) {
                ValueRow(title: "Minimum pay", value: "$\(Int(minimumPay)) per job")
                BountySlider(value: $minimumPay, range: 5...40, label: "Minimum pay")
                ValueRow(title: "Travel radius", value: "\(Int(radius)) mi")
                BountySlider(value: $radius, range: 1...7, label: "Travel radius")

                SegmentedPill(
                    options: [(WorkMode.remote, "Remote"), (.inPerson, "In person"), (.both, "Both")],
                    selection: $workMode
                )

                HStack(spacing: 8) {
                    Text("Hide")
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(hidden, id: \.self) { category in
                        Chip(label: category, tone: .grey)
                    }
                    Chip(label: "+ Add", tone: .yellow)
                }

                Toggle(isOn: $quietHours) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Quiet hours")
                            .bountyType(.bodyStrong)
                            .foregroundStyle(BountyColor.inkPrimary)
                        Text("No offers 10 PM – 8 AM")
                            .bountyType(.footnote)
                            .foregroundStyle(BountyColor.inkSecondary)
                    }
                }
                .tint(BountyColor.green)
            }
            .padding(16)
            .borderedCard()
            .entrance(.rest(0))
        } bottom: {
            PillButton(title: "Start matching", icon: .sparkles, action: onContinue)
        }
    }

    private func toggle(_ slot: Int) {
        if freeSlots.contains(slot) {
            freeSlots.remove(slot)
        } else {
            freeSlots.insert(slot)
        }
    }
}

private struct ValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .contentTransition(.numericText())
        }
        .bountyType(.bodyStrong)
        .foregroundStyle(BountyColor.inkPrimary)
    }
}

#Preview {
    OnboardingView(onComplete: {})
        .environment(AppServices())
}
