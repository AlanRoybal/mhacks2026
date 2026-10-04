import SwiftUI
import TwinKit
import UserNotifications

/// 04 Twin review.
struct TwinView: View {
    @Environment(AppServices.self) private var services
    @Environment(AppRouter.self) private var router
    @State private var profile: TwinProfile?
    @State private var settings: TwinSettings?
    @State private var me: MeProfile?
    @State private var showsSettings = false
    @State private var editingSkills: [TwinKit.TwinSkill] = []
    @State private var isEditing = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isAddingSource = false
    /// Bumped when an import starts, so the progress poller restarts.
    @State private var importRun = 0

    private let sampleSkills = [
        TwinKit.TwinSkill(id: "logo-design", name: "Logo & brand design", confidence: 0.94, source: .email),
        TwinKit.TwinSkill(id: "graphic-design", name: "Graphic design", confidence: 0.90, source: .linkedIn),
        TwinKit.TwinSkill(id: "calculus-tutoring", name: "Calculus tutoring", confidence: 0.82, source: .email),
        TwinKit.TwinSkill(id: "product-photography", name: "Product photography", confidence: 0.76, source: .email)
    ]

    /// Sample skills only when there's no backend (previews and sample mode).
    private var skills: [TwinKit.TwinSkill] { services.profile == nil ? sampleSkills : profile?.skills ?? [] }

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowLavender, height: 320), alwaysBounces: true) {
            ScreenTitle(title: "Your twin") {
                HStack(spacing: 8) {
                    if let readiness = settings?.readiness {
                        Chip(label: readiness.ready ? "Ready to match" : "Not ready", tone: readiness.ready ? .mint : .coral)
                    } else if isLoading {
                        Chip(label: "Refreshing", tone: .grey)
                    }
                    IconButton(icon: .userRound, label: "Account") { showsSettings = true }
                }
            }
            .entrance(.top)

            StackCard(tone: .lavender, height: 150, bandTop: 108) {
                HStack(alignment: .top, spacing: 16) {
                    StickerView(sticker: .twin, size: 110)
                        .padding(.top, 18)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile?.headline ?? "Your work twin")
                            .bountyType(.headline)
                        Text(profile?.roles.first ?? (services.profile == nil ? "Designer & tutor · Ann Arbor" : "Add your experience below"))
                            .bountyType(.subhead)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        HStack(alignment: .top, spacing: 18) {
                            TwinStat(value: "\(skills.count)", label: "skills")
                            TwinStat(value: "\(Set(skills.map { $0.source.rawValue }).count)", label: "sources")
                            TwinStat(value: averageConfidence, label: "confident")
                        }
                        .padding(.top, 6)
                    }
                    .foregroundStyle(BountyColor.inkPrimary)
                    .padding(.top, 22)
                }
                .padding(.leading, 14)
            }
            .entrance(.top)

            if let readiness = settings?.readiness, !readiness.ready || !readiness.recommended.isEmpty {
                ReadinessPanel(readiness: readiness, onFix: fix)
                    .entrance(.rest(0))
            }

            SectionHeader(title: "Skills it found", trailing: "Edit", trailingColor: BountyColor.lavenderInk, trailingType: .bodyStrong) {
                editingSkills = skills
                isEditing = true
            }
            .entrance(.rest(0))

            if let errorMessage {
                Text(errorMessage)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            }

            if skills.isEmpty {
                Text("No skills yet. Add a source below, or add skills yourself.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .entrance(.rest(1))
            } else {
            VStack(spacing: 0) {
                ForEach(skills) { skill in
                    SkillRow(skill: skill)
                    if skill.id != skills.last?.id {
                        BountyColor.divider.frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
            .borderedCard()
            .entrance(.rest(1))
            }

            PillButton(title: "Add a skill", icon: .plus, style: .secondary) {
                addSkill()
            }
            .entrance(.rest(2))

            SectionHeader(title: "Sources")
                .entrance(.rest(3))

            if let ingest = settings?.ingest, ingest.status == "processing" || (ingest.status == "failed" && importRun > 0) {
                ImportStatusBanner(ingest: ingest)
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }

            TwinSourcesList(
                importedSources: Set(settings?.ingest.sources ?? []),
                allowsResync: true,
                isBusy: $isAddingSource,
                onImportStarted: { importRun += 1 }
            )
            .entrance(.rest(3))

            if let stats = me?.stats {
                ReliabilityCard(stats: stats)
                    .entrance(.rest(4))
            }
        }
        .task { await load() }
        // While the server reads an import, check every 2 s and show the new skills when it's done.
        .task(id: importRun) { await followImport() }
        .refreshable { await load() }
        .sheet(isPresented: $showsSettings, onDismiss: { Task { await load() } }) { SettingsView() }
        .sheet(isPresented: $isEditing) {
            SkillEditor(skills: $editingSkills, isSaving: isLoading) {
                await saveSkills()
            }
        }
    }

    private var averageConfidence: String {
        guard !skills.isEmpty else { return "0%" }
        return (skills.map(\.confidence).reduce(0, +) / Double(skills.count)).formatted(.percent.precision(.fractionLength(0)))
    }

    private func load() async {
        guard let service = services.profile else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            profile = try await service.profile()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        if let api = services.api {
            settings = try? await api.request(.get, "twin")
            me = try? await api.request(.get, "me")
        }
        // An import from setup (or another screen) is still running: follow it here too.
        if settings?.ingest.status == "processing" { importRun += 1 }
    }

    private func followImport() async {
        guard let api = services.api, importRun > 0 else { return }
        while !Task.isCancelled {
            if let fresh: TwinSettings = try? await api.request(.get, "twin") {
                withAnimation(Motion.press) { settings = fresh }
                if fresh.ingest.status != "processing" {
                    await load()
                    return
                }
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func addSkill() {
        editingSkills = skills
        editingSkills.append(TwinKit.TwinSkill(id: UUID().uuidString, name: "", confidence: 1, source: .user))
        isEditing = true
    }

    /// What each readiness item's button does.
    private func fix(_ item: String) {
        switch item {
        case "skills": addSkill()
        case "payouts": router.select(.earnings)
        case "notifications":
            Task {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .timeSensitive])) ?? false
                if granted {
                    UIApplication.shared.registerForRemoteNotifications()
                } else if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    await UIApplication.shared.open(url)
                }
                try? await Task.sleep(for: .seconds(2))
                await load()
            }
        default: showsSettings = true
        }
    }

    private func saveSkills() async {
        guard let service = services.profile else {
            isEditing = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let cleaned = editingSkills.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            profile = try await service.update(skills: cleaned)
            errorMessage = nil
            isEditing = false
            // Skills count toward readiness.
            if let api = services.api { settings = try? await api.request(.get, "twin") }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Progress of the latest import, or why it failed.
private struct ImportStatusBanner: View {
    let ingest: TwinSettings.Ingest

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if ingest.status == "processing" {
                ProgressView()
            } else {
                IconGlyph(icon: .refresh, size: 18)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ingest.status == "processing" ? "Reading your new source\u{2026}" : "That import didn\u{2019}t work")
                    .bountyType(.subheadStrong)
                Text(ingest.status == "processing" ? "New skills show up above, usually within a minute." : ingest.error ?? "Try again or use a different file.")
                    .bountyType(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(ingest.status == "processing" ? BountyColor.lavenderInk : BountyColor.creamInk)
        .padding(14)
        .tintedPanel(ingest.status == "processing" ? BountyColor.lavenderSoft : BountyColor.cream, radius: BountyRadius.row)
    }
}

/// What the twin still needs before it gets offers (US-08). Required items first, then suggestions.
private struct ReadinessPanel: View {
    let readiness: TwinSettings.Readiness
    let onFix: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(readiness.ready ? "Ready. A couple of things would help:" : "Before your twin can find work:")
                .bountyType(.bodyStrong)
            ForEach(readiness.missing + readiness.recommended, id: \.self) { item in
                let required = readiness.missing.contains(item)
                HStack(spacing: 10) {
                    StatusBadge(status: required ? .todo : .active)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.title(item)).bountyType(.subheadStrong)
                        Text(required ? "Required" : "Recommended").bountyType(.caption)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button(Self.action(item)) { onFix(item) }
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.lavenderInk)
                }
            }
        }
        .foregroundStyle(BountyColor.inkPrimary)
        .padding(16)
        .tintedPanel(readiness.ready ? BountyColor.lavenderSoft : BountyColor.cream, radius: BountyRadius.row)
    }

    static func title(_ item: String) -> String {
        switch item {
        case "skills": "Add at least one skill"
        case "notifications": "Turn on offer notifications"
        case "payouts": "Set up Stripe payouts"
        case "location": "Set where you work from"
        case "availability": "Add your availability"
        default: item.capitalized
        }
    }

    static func action(_ item: String) -> String {
        switch item {
        case "skills": "Add"
        case "notifications": "Turn on"
        case "payouts": "Set up"
        default: "Open"
        }
    }
}

/// Acceptance, completion and reliability (US-58). Reliability affects matching.
private struct ReliabilityCard: View {
    let stats: MeProfile.Stats

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Track record")
                .bountyType(.bodyStrong)
            HStack(alignment: .top, spacing: 18) {
                TwinStat(value: stats.reliability.formatted(.percent.precision(.fractionLength(0))), label: "reliable")
                TwinStat(value: stats.acceptRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–", label: "accepted")
                TwinStat(value: stats.completionRate.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–", label: "completed")
                TwinStat(value: stats.workerRating.map { "★\($0.formatted())" } ?? "–", label: "rating")
            }
            Text("\(stats.jobsCompleted) jobs done. Expired offers and withdrawals lower reliability.")
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkSecondary)
        }
        .foregroundStyle(BountyColor.inkPrimary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .borderedCard()
    }
}

private struct TwinStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).bountyType(.moneyM)
            Text(label).bountyType(.footnote)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SkillRow: View {
    let skill: TwinKit.TwinSkill

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(skill.name)
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Chip(label: sourceName, tone: skill.source == .rating ? .mint : skill.source == .linkedIn ? .lavender : .sky)
            }
            if let record = skill.trackRecord, record.jobs > 0 {
                // Like a rideshare rating, but per skill: what posters said about real jobs.
                Text("\(record.averageStars.map { "\($0.formatted(.number.precision(.fractionLength(1))))\u{2605} · " } ?? "")\(record.jobs) rated job\(record.jobs == 1 ? "" : "s")")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.mintInk)
            }
            HStack(spacing: 10) {
                Meter(value: skill.confidence)
                Text(skill.confidence, format: .percent.precision(.fractionLength(0)))
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
        .padding(.vertical, 12)
    }

    private var sourceName: String {
        switch skill.source {
        case .linkedIn: "LinkedIn"
        case .resume: "Résumé"
        case .email: "Email"
        case .user: "Added by you"
        case .rating: "Proven"
        }
    }
}

private struct SkillEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var skills: [TwinKit.TwinSkill]
    let isSaving: Bool
    let onSave: () async -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach($skills) { $skill in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Skill", text: $skill.name)
                        HStack {
                            Text("Confidence")
                            Slider(value: $skill.confidence, in: 0...1)
                            Text(skill.confidence, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                        }
                        .font(.footnote)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            skills.removeAll { $0.id == skill.id }
                        }
                    }
                }
                Button("Add skill") {
                    skills.append(TwinKit.TwinSkill(id: UUID().uuidString, name: "", confidence: 1, source: .user))
                }
            }
            .navigationTitle("Edit skills")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") { Task { await onSave() } }
                        .disabled(isSaving)
                }
            }
        }
    }
}

#Preview {
    TwinView()
        .environment(AppServices())
}
