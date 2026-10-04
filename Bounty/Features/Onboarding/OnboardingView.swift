import AuthenticationServices
import SwiftUI
import TwinKit
import UniformTypeIdentifiers

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
                WorkPreferencesView(onBack: { go(to: .profileImport) }, onContinue: { transition.perform(onComplete) })
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
        BountyScreen(glow: ScreenGlow(BountyColor.glowLavender, height: 460), spacing: 20) {
            // Logo/Lockup at 30 pt (Figma 01 Welcome).
            BountyLockup(height: 30)
                .padding(.top, 8)
                .entrance(.top)

            StackCard(tone: .lavender, height: 300, bandTop: 186) {
                ZStack(alignment: .topLeading) {
                    StickerView(sticker: .twin, size: 170)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 26)
                    VStack(alignment: .leading, spacing: 10) {
                        Chip(label: "Your digital twin", tone: .dark)
                        Text("Finds paid jobs that fit you")
                            .bountyType(.headline)
                            .foregroundStyle(BountyColor.inkPrimary)
                    }
                    .padding(.leading, 20)
                    .padding(.top, 212)
                }
            }
            .entrance(.top)

            VStack(spacing: 20) {
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
                SignInWithAppleButton(.continue) { request in
                    request.requestedScopes = [.fullName, .email]
                } onCompletion: { result in
                    signInWithApple(result)
                }
                .signInWithAppleButtonStyle(.black)
                .frame(height: 56)
                .clipShape(Capsule())
                .disabled(isSigningIn)
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

    private func signInWithApple(_ result: Result<ASAuthorization, Error>) {
        guard services.api != nil else {
            onContinue()
            return
        }
        guard case .success(let authorization) = result,
              let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            if case .failure(let error) = result { signInError = error.localizedDescription }
            return
        }
        isSigningIn = true
        signInError = nil
        Task {
            defer { isSigningIn = false }
            do {
                try await services.signInWithApple(credential)
                onContinue()
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
    @Environment(AppServices.self) private var services
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var addedGmail = false
    @State private var addedLinkedIn = false
    @State private var addedCalendar = false
    @State private var isPickingLinkedIn = false
    @State private var addedResume = false
    @State private var isPickingResume = false
    @State private var isImporting = false
    @State private var importError: String?

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
                SourceRow(title: "Gmail", detail: "Read-only · sent mail", isAdded: addedGmail) {
                    StickerTile(sticker: .mail, background: BountyColor.sky)
                } onAdd: {
                    importError = "Gmail needs a Google OAuth client before it can connect."
                }
                SourceRow(title: "LinkedIn profile PDF", detail: isImporting ? "Importing…" : "Profile → Save to PDF", isAdded: addedLinkedIn) {
                    IconGlyph(icon: .linkedin, size: 24)
                        .foregroundStyle(BountyColor.lavenderInk)
                        .frame(width: 52, height: 52)
                        .background(BountyColor.lavenderSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                } onAdd: {
                    isPickingLinkedIn = true
                }
                SourceRow(title: "Résumé", detail: isImporting ? "Importing…" : "PDF", isAdded: addedResume) {
                    StickerTile(sticker: .book, background: BountyColor.mint)
                } onAdd: {
                    isPickingResume = true
                }
                SourceRow(title: "Calendar", detail: "Free/busy, stays on device", isAdded: addedCalendar) {
                    StickerTile(sticker: .calendar, background: BountyColor.cream)
                } onAdd: {
                    connectCalendar()
                }
            }
            .entrance(.rest(0))

            if let importError {
                Text(importError)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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
                .disabled(isImporting)
        }
        .fileImporter(isPresented: $isPickingLinkedIn, allowedContentTypes: [.pdf, .zip]) { result in
            importDocument(result, isResume: false)
        }
        .background {
            // A second file importer on the same view replaces the first, so this one hangs off a background view.
            Color.clear.fileImporter(isPresented: $isPickingResume, allowedContentTypes: [.pdf]) { result in
                importDocument(result, isResume: true)
            }
        }
    }

    private func importDocument(_ result: Result<URL, Error>, isResume: Bool) {
        guard case .success(let url) = result else {
            if case .failure(let error) = result { importError = error.localizedDescription }
            return
        }
        let markAdded = { withAnimation(Motion.press) { if isResume { addedResume = true } else { addedLinkedIn = true } } }
        guard let ingestion = services.profileIngestion else {
            markAdded()
            return
        }
        isImporting = true
        importError = nil
        Task {
            defer { isImporting = false }
            do {
                let source: ProfileDocumentSource = isResume ? .resume : url.pathExtension.lowercased() == "zip" ? .linkedInExport : .linkedInPDF
                _ = try await ingestion.ingest(fileURL: url, source: source)
                markAdded()
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func connectCalendar() {
        guard let availability = services.availability else {
            withAnimation(Motion.press) { addedCalendar = true }
            return
        }
        importError = nil
        Task {
            guard await availability.requestAccess() else {
                importError = "Calendar access was not granted. You can enable it in Settings."
                return
            }
            do {
                try await availability.sync()
                withAnimation(Motion.press) { addedCalendar = true }
            } catch {
                importError = error.localizedDescription
            }
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

/// Follows the server's import (`GET /twin` → `ingest`) until the skills are extracted (US-03).
private struct BuildingTwinView: View {
    @Environment(AppServices.self) private var services
    let onCancel: () -> Void
    let onContinue: () -> Void
    @State private var twin: TwinSettings?
    @State private var waitedTooLong = false

    private var status: String { twin?.ingest.status ?? "processing" }

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowLavender, height: 460), spacing: 14) {
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
                    Chip(label: chipText, tone: .dark)
                        .padding(.leading, 20)
                        .padding(.top, 158)
                }
            }
            .entrance(.top)

            Text(headline)
                .bountyType(.display)
                .foregroundStyle(BountyColor.inkPrimary)
                .entrance(.rest(0))

            VStack(spacing: 4) {
                switch status {
                case "done":
                    BuildRow(status: .done, title: "Read your files", detail: "Skills, roles and education")
                    BuildRow(status: .done, title: "Found \(twin?.skills.count ?? 0) skills",
                             detail: twin?.skills.prefix(3).map(\.name).joined(separator: ", ") ?? "")
                case "failed":
                    BuildRow(status: .todo, title: "Couldn\u{2019}t read that file", detail: twin?.ingest.error ?? "Try a different file.")
                case "idle":
                    BuildRow(status: .todo, title: "No files added", detail: "You can add skills by hand on your Twin page.")
                default:
                    BuildRow(status: .active, title: "Reading your files", detail: waitedTooLong ? "Still working. You can keep going; it finishes in the background." : "Usually under a minute")
                    BuildRow(status: .todo, title: "Extracting skills", detail: "Each one keeps its source and confidence")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .borderedCard()
            .entrance(.rest(1))
        } bottom: {
            if status == "failed" {
                VStack(spacing: 10) {
                    PillButton(title: "Try another file", icon: .refresh, action: onCancel)
                    PillButton(title: "Continue without it", style: .secondary, action: onContinue)
                }
            } else {
                PillButton(title: status == "processing" ? "Keep going in the background" : "Continue", style: status == "processing" ? .secondary : .primary, action: onContinue)
            }
        }
        .task { await follow() }
    }

    private var chipText: String {
        switch status {
        case "done": "\(twin?.skills.count ?? 0) skills found"
        case "failed": "Import failed"
        case "idle": "Nothing to read"
        default: "Reading"
        }
    }

    private var headline: String {
        switch status {
        case "done": "Your twin is ready to review"
        case "failed": "That file didn\u{2019}t work"
        case "idle": "Start from scratch"
        default: "Building your twin\u{2026}"
        }
    }

    /// Polls every 2 s. Without a backend (previews, sample mode) it moves on after a moment.
    private func follow() async {
        guard let api = services.api else {
            try? await Task.sleep(for: Motion.autoAdvance)
            if !Task.isCancelled { onContinue() }
            return
        }
        let started = Date.now
        while !Task.isCancelled {
            if let fresh: TwinSettings = try? await api.request(.get, "twin") {
                withAnimation(Motion.press) { twin = fresh }
                if fresh.ingest.status != "processing" { return }
            }
            waitedTooLong = Date.now.timeIntervalSince(started) > 45
            try? await Task.sleep(for: .seconds(2))
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

/// Availability and work preferences (US-06/07). The last onboarding step, and Settings › Work preferences.
struct WorkPreferencesView: View {
    @Environment(AppServices.self) private var services
    /// Settings shows a title and a Save button instead of the onboarding steps.
    var inSettings = false
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var freeSlots: Set<Int> = [2, 4, 5, 6, 7, 9, 11, 12, 14, 15, 16, 17, 18, 19]
    @State private var minimumPay = 15.0
    @State private var radius = 3.0
    @State private var workMode = WorkMode.both
    /// Categories the twin never offers.
    @State private var hidden: Set<JobCategory> = [.moving]
    @State private var quietHours = true
    @State private var isSaving = false
    @State private var saveError: String?

    enum WorkMode: Hashable {
        case remote, inPerson, both
    }

    private let days = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        BountyScreen {
            NavRow(leadingAction: onBack) {
                if inSettings {
                    Text("Work preferences").bountyType(.bodyStrong)
                } else {
                    ProgressDots(total: 4, current: 3)
                }
            } trailing: {
                if !inSettings { StepLabel(text: "4 of 4") }
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

                VStack(alignment: .leading, spacing: 8) {
                    Text("Never offer me")
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(JobCategory.allCases.filter { $0 != .other }) { category in
                                ChoiceChip(label: category.displayName, isSelected: hidden.contains(category)) {
                                    if hidden.contains(category) { hidden.remove(category) } else { hidden.insert(category) }
                                }
                            }
                        }
                    }
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

            if let saveError {
                Text(saveError)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            }
        } bottom: {
            PillButton(title: isSaving ? "Saving…" : inSettings ? "Save" : "Start matching", icon: inSettings ? .check : .sparkles) {
                saveAndContinue()
            }
            .disabled(isSaving)
        }
        .task { await loadSaved() }
    }

    /// Starts from what the server has, so returning to this screen doesn't reset anything.
    private func loadSaved() async {
        guard let api = services.api, let twin: TwinSettings = try? await api.request(.get, "twin") else { return }
        let prefs = twin.prefs
        minimumPay = min(40, max(5, prefs.minPay))
        if let miles = prefs.maxRadiusMiles { radius = min(7, max(1, miles.rounded())) }
        workMode = prefs.remoteOk && prefs.inPersonOk ? .both : prefs.remoteOk ? .remote : .inPerson
        hidden = Set(prefs.blockedCategories.compactMap(JobCategory.init(rawValue:)))
        quietHours = prefs.quietHours != nil
        if let weekly = twin.availability?.weekly, weekly.count == 168 {
            let hours = Array(weekly)
            let ranges = [8..<12, 12..<17, 17..<22]
            freeSlots = Set((0..<21).filter { slot in ranges[slot % 3].contains { hours[slot / 3 * 24 + $0] == "1" } })
        }
    }

    private func saveAndContinue() {
        guard let api = services.api else {
            onContinue()
            return
        }
        isSaving = true
        saveError = nil
        Task {
            defer { isSaving = false }
            do {
                try await api.send(.put, "twin/prefs", body: TwinPreferencesUpdate(
                    minPay: minimumPay,
                    maxRadiusMiles: radius,
                    blockedCategories: hidden.map(\.rawValue).sorted(),
                    remoteOk: workMode != .inPerson,
                    inPersonOk: workMode != .remote,
                    tz: TimeZone.current.identifier,
                    quietHours: quietHours ? QuietHours(start: "22:00", end: "08:00") : nil
                ))
                try await api.send(.put, "twin/availability", body: TwinAvailabilityUpdate(
                    tz: TimeZone.current.identifier,
                    weekly: weeklyAvailability,
                    busy: []
                ))
                onContinue()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private var weeklyAvailability: String {
        let ranges = [8..<12, 12..<17, 17..<22]
        var hours = Array(repeating: "0", count: 168)
        for slot in freeSlots {
            let day = slot / 3
            let block = slot % 3
            for hour in ranges[block] { hours[day * 24 + hour] = "1" }
        }
        return hours.joined()
    }

    private func toggle(_ slot: Int) {
        if freeSlots.contains(slot) {
            freeSlots.remove(slot)
        } else {
            freeSlots.insert(slot)
        }
    }
}

/// The parts of `GET /twin` this screen and Settings read.
struct TwinSettings: Decodable, Sendable {
    struct Prefs: Decodable, Sendable {
        let minPay: Double
        let maxRadiusMiles: Double?
        let blockedCategories: [String]
        let remoteOk: Bool
        let inPersonOk: Bool
        let quietHours: QuietHoursWindow?
    }

    struct QuietHoursWindow: Decodable, Sendable {
        let start: String
        let end: String
    }

    struct Availability: Decodable, Sendable {
        let weekly: String?
    }

    /// `ready` once nothing in `missing` is left; `recommended` items help matching but aren't required (US-08).
    struct Readiness: Decodable, Sendable {
        let ready: Bool
        let missing: [String]
        let recommended: [String]
    }

    struct Ingest: Decodable, Sendable {
        /// `idle`, `processing`, `done` or `failed`.
        let status: String
        let error: String?
    }

    let prefs: Prefs
    let availability: Availability?
    let readiness: Readiness
    let ingest: Ingest
    let skills: [Skill]

    struct Skill: Decodable, Sendable {
        let name: String
    }
}

private struct QuietHours: Encodable, Sendable {
    let start: String
    let end: String
}

private struct TwinPreferencesUpdate: Encodable, Sendable {
    let minPay: Double
    let maxRadiusMiles: Double
    let blockedCategories: [String]
    let remoteOk: Bool
    let inPersonOk: Bool
    let tz: String
    let quietHours: QuietHours?
}

private struct TwinAvailabilityUpdate: Encodable, Sendable {
    let tz: String
    let weekly: String
    let busy: [BusyWindow]
}

private struct BusyWindow: Encodable, Sendable {
    let start: Date
    let end: Date
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
