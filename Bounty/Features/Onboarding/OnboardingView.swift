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

// MARK: - 02 Profile import

private struct ProfileImportView: View {
    let onBack: () -> Void
    let onContinue: () -> Void

    @State private var isImporting = false

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

            Text("Add what you\u{2019}ve done. Your twin keeps the skills it finds, not your files.")
                .bountyType(.body)
                .foregroundStyle(BountyColor.inkSecondary)
                .entrance(.top)

            TwinSourcesList(isBusy: $isImporting)
                .entrance(.rest(0))

            HStack(alignment: .top, spacing: 10) {
                IconGlyph(icon: .lock, size: 18)
                    .foregroundStyle(BountyColor.lavenderInk)
                Text("LinkedIn sign-in only shares your name and photo. The profile PDF adds your experience. You can add or sync any of these later from the Twin tab.")
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
    @State private var isReadingCalendar = false
    @State private var calendarNote: String?
    /// Set when Fill from calendar finds no linked calendar; shows the link prompt instead of guessing.
    @State private var showsLinkPrompt = false
    @State private var isLinkingCalendar = false

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
                    Text("When you\u{2019}re free")
                        .bountyType(.bodyStrong)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if services.availability != nil {
                        Button(isReadingCalendar ? "Reading\u{2026}" : "Fill from calendar") {
                            Task { await fillFromCalendar() }
                        }
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.lavenderInk)
                        .disabled(isReadingCalendar)
                    }
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

                if showsLinkPrompt {
                    CalendarLinkPrompt { isLinkingCalendar = true }
                        .transition(.opacity.combined(with: .offset(y: -6)))
                } else {
                    Text(calendarNote ?? "Tap a block to switch it between free (green) and busy. Rows are mornings, afternoons and evenings.")
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                }
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
        .sheet(isPresented: $isLinkingCalendar) {
            CalendarLinkSheet { _ in
                withAnimation(Motion.press) { showsLinkPrompt = false }
                fillFreeSlots()
            }
        }
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
                // In-person matching measures distance from here; without it no in-person job is offered.
                let here = workMode == .remote ? nil : await JobLocationProvider().current()
                try await api.send(.put, "twin/prefs", body: TwinPreferencesUpdate(
                    minPay: minimumPay,
                    maxRadiusMiles: radius,
                    blockedCategories: hidden.map(\.rawValue).sorted(),
                    remoteOk: workMode != .inPerson,
                    inPersonOk: workMode != .remote,
                    tz: TimeZone.current.identifier,
                    quietHours: quietHours ? QuietHours(start: "22:00", end: "08:00") : nil,
                    base: here.map { Coordinate(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude) }
                ))
                try await api.send(.put, "twin/availability", body: TwinAvailabilityUpdate(
                    tz: TimeZone.current.identifier,
                    weekly: weeklyAvailability,
                    // Keep the calendar's busy times; an empty list would erase what the calendar sync sent.
                    busy: calendarBusy()
                ))
                onContinue()
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    /// The next two weeks of busy times from the linked calendars (none when nothing is linked). Only
    /// start and end times leave the phone.
    private func calendarBusy() -> [BusyWindow] {
        services.linkedBusyBlocks(horizon: 14 * 86_400).map { BusyWindow(start: $0.start, end: $0.end) }
    }

    /// Fills from the linked calendars. With none linked it offers "Link calendar" rather than reading
    /// an empty calendar as "free all week".
    private func fillFromCalendar() async {
        guard services.isCalendarLinked else {
            withAnimation(Motion.press) { showsLinkPrompt = true }
            return
        }
        isReadingCalendar = true
        defer { isReadingCalendar = false }
        switch await services.syncCalendar() {
        case .synced: fillFreeSlots()
        case .notLinked, .accessDenied: withAnimation(Motion.press) { showsLinkPrompt = true }
        case .failed(let error): calendarNote = "Couldn\u{2019}t sync your calendar: \(error)"
        }
    }

    /// Marks each morning, afternoon and evening of the coming week free unless the calendar has
    /// something in it. The worker can still tap blocks to adjust.
    private func fillFreeSlots() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let busy = services.linkedBusyBlocks(startingAt: today, horizon: 7 * 86_400)
        let ranges = [8..<12, 12..<17, 17..<22]
        var free: Set<Int> = []
        for offset in 0..<7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            // Calendar weekday: 1 is Sunday. The grid starts on Monday.
            let column = (calendar.component(.weekday, from: day) + 5) % 7
            for (row, hours) in ranges.enumerated() {
                guard let start = calendar.date(bySettingHour: hours.lowerBound, minute: 0, second: 0, of: day),
                      let end = calendar.date(bySettingHour: hours.upperBound, minute: 0, second: 0, of: day) else { continue }
                if !busy.contains(where: { $0.start < end && $0.end > start }) { free.insert(column * 3 + row) }
            }
        }
        withAnimation(Motion.press) { freeSlots = free }
        calendarNote = busy.isEmpty
            ? "Your linked calendars are clear this week, so every block is free. Tap any you want to keep for yourself."
            : "Filled from your calendar. Blocks with events are busy; tap any block to change it."
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
        /// Every import so far, e.g. "resume_pdf", "linkedin_pdf", "gmail_sent".
        let sources: [String]?
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

/// Shown under the availability grid when Fill from calendar has no linked calendar to read.
private struct CalendarLinkPrompt: View {
    let onLink: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TitleSubtitle(
                title: "You don\u{2019}t have a calendar linked",
                subtitle: "Link one so your twin knows when you\u{2019}re busy. You choose which calendars, and only start and end times leave your phone.",
                subtitleType: .footnote
            )
            PillButton(title: "Link calendar", icon: .calendar, style: .secondary, action: onLink)
        }
        .padding(14)
        .tintedPanel(BountyColor.lavenderSoft, radius: BountyRadius.row)
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
    /// Left out (not null) when the location is unavailable, so a saved base isn't erased.
    let base: Coordinate?
}

private struct Coordinate: Encodable, Sendable {
    let latitude: Double
    let longitude: Double
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
