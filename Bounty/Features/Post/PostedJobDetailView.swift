import SwiftUI

/// A job the poster posted, followed live (plan step 6, feature 11), in Alan's visual style.
/// Shows where the job is on the six-step timeline, who's doing it, and what to do next.
/// Polls while open, so status changes from the backend appear on their own.
struct PostedJobDetailView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store
    @State private var history: [TimelineEntry] = []
    @State private var confirmsCancel = false
    @State private var isCanceling = false
    @State private var actionError: String?

    private var job: PostedJob? { store.job(router.posterJobId) }

    var body: some View {
        BountyScreen {
            NavRow(leadingAction: router.back) {
                if let job {
                    Chip(label: job.status.displayName, tone: job.status.chipTone)
                }
            } trailing: {
                EmptyView()
            }
            .entrance(.top)

            if let job {
                HStack(spacing: 14) {
                    StickerTile(sticker: job.sticker, background: job.tileColor, size: 64, stickerSize: 54, radius: 19)
                    TitleSubtitle(
                        title: job.title,
                        subtitle: "\(job.payShort) · Due \(job.deadlineText)",
                        titleType: .headline
                    )
                }
                .entrance(.top)

                if let note = statusNote(for: job) {
                    HStack(spacing: 12) {
                        StickerView(sticker: note.sticker, size: 40)
                        Text(note.text)
                            .bountyType(.subhead)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(note.ink)
                    .padding(14)
                    .tintedPanel(note.fill, radius: BountyRadius.row)
                    .entrance(.top)
                }

                if let worker = job.worker {
                    HStack(spacing: 12) {
                        InitialsAvatar(initials: initials(worker.name), background: BountyColor.lavenderSoft, foreground: BountyColor.lavenderInk)
                        TitleSubtitle(
                            title: worker.name,
                            subtitle: worker.rating.map { "★ \($0.formatted(.number.precision(.fractionLength(1))))" } ?? "New worker"
                        )
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .borderedCard(radius: BountyRadius.row)
                    .entrance(.rest(0))

                    // Checked by the server the moment the worker tapped Start.
                    if let check = job.startCheck {
                        Label(check.summary, icon: .mapPin)
                            .bountyType(.footnote)
                            .foregroundStyle(BountyColor.mintInk)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .tintedPanel(BountyColor.mint, radius: BountyRadius.row)
                            .entrance(.rest(0))
                    }
                }

                if let risk = job.risk {
                    EscrowRiskCard(risk: risk)
                        .entrance(.rest(0))
                }

                // Step 9: paid or refunded jobs ask for a rating, then show the one given.
                RateWorkerCard(job: job)
                    .entrance(.rest(0))

                if job.status != .draft {
                    StatusTimeline(job: job)
                        .padding(16)
                        .borderedCard()
                        .entrance(.rest(1))

                    MoneyTrailCard(jobId: job.id, refreshKey: job.status.rawValue)
                        .entrance(.rest(1))
                }

                if !history.isEmpty {
                    JobHistoryCard(entries: history, payment: job.payment)
                        .entrance(.rest(1))
                }

                if let actionError {
                    Text(actionError)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.red)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("What counts as done")
                            .bountyType(.bodyStrong)
                            .foregroundStyle(BountyColor.inkPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Chip(label: job.status == .draft ? "Editable" : "Locked", tone: .grey)
                    }
                    ForEach(job.checklist) { item in
                        HStack(spacing: 12) {
                            StatusBadge(status: badge(for: item, in: job))
                            TitleSubtitle(
                                title: item.text,
                                subtitle: item.evidenceSummary,
                                titleType: .subhead,
                                subtitleType: .footnote
                            )
                        }
                        .padding(.vertical, 6)
                    }
                }
                .padding(16)
                .borderedCard()
                .entrance(.rest(2))
            } else {
                JobUnavailable()
            }
        } bottom: {
            if let job {
                switch job.status {
                case .inReview:
                    PillButton(title: "Review the work", icon: .shieldCheck) {
                        router.open(.reviewProof, posterJob: job.id)
                    }
                default:
                    if job.allows("cancel") {
                        PillButton(title: isCanceling ? "Canceling\u{2026}" : "Cancel and refund", icon: .x, style: .secondary) {
                            confirmsCancel = true
                        }
                        .disabled(isCanceling)
                    }
                }
            }
        }
        .confirmationDialog("Cancel this job?", isPresented: $confirmsCancel, titleVisibility: .visible) {
            Button("Cancel job and refund \(refundText)", role: .destructive) {
                Task { await cancel() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("No one has accepted it yet, so you get a full refund, including the fee.")
        }
        .task {
            guard let jobId = router.posterJobId else { return }
            var lastStatus: PostedJobStatus?
            while !Task.isCancelled {
                let fresh = await store.refresh(jobId: jobId)
                // The history only changes when the status does.
                if history.isEmpty || fresh?.status != lastStatus {
                    history = await store.timeline(jobId: jobId)
                    lastStatus = fresh?.status
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Everything the poster paid, fee included.
    private var refundText: String {
        guard let job = store.job(router.posterJobId) else { return "" }
        return (job.totalAmount ?? job.payAmount).formatted(.currency(code: "USD"))
    }

    private func cancel() async {
        guard let job else { return }
        isCanceling = true
        defer { isCanceling = false }
        do {
            try await store.cancel(job)
            history = await store.timeline(jobId: job.id)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private struct StatusNote {
        let text: String
        let sticker: Sticker
        let fill: Color
        let ink: Color
    }

    /// The one thing the poster should know right now.
    private func statusNote(for job: PostedJob) -> StatusNote? {
        switch job.status {
        case .draft:
            return StatusNote(text: "Not live yet. Workers see it once it’s funded through checkout.", sticker: .coins, fill: BountyColor.cream, ink: BountyColor.creamInk)
        case .funded, .offered, .accepted, .inProgress, .submitted:
            return StatusNote(text: "\(job.payShort) is held safely. It releases when the proof passes and you approve, or the review window closes.", sticker: .shield, fill: BountyColor.mint, ink: BountyColor.mintInk)
        case .inReview:
            return StatusNote(text: "The work is in. Your turn to review.", sticker: .check, fill: BountyColor.cream, ink: BountyColor.creamInk)
        case .disputed:
            return StatusNote(text: "You disputed this job. The AI takes a second look, then a person decides.", sticker: .shield, fill: BountyColor.cream, ink: BountyColor.creamInk)
        case .released:
            return StatusNote(text: "Done. \(job.worker?.name ?? "The worker") was paid \(job.payShort).", sticker: .coins, fill: BountyColor.mint, ink: BountyColor.mintInk)
        case .refunded:
            return StatusNote(text: "Refunded. Your \((job.totalAmount ?? job.payAmount).formatted(.currency(code: "USD"))) is on its way back.", sticker: .coins, fill: BountyColor.pill, ink: BountyColor.inkPill)
        }
    }

    private func badge(for item: ChecklistItem, in job: PostedJob) -> StepStatus {
        guard let verdict = job.verdict(for: item) else { return .todo }
        return verdict.pass && verdict.confidence >= Verdict.reviewThreshold ? .done : .active
    }

    private func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// Every status change from the server's ledger, newest first, with who did it (US-17/49).
struct JobHistoryCard: View {
    let entries: [TimelineEntry]
    var payment: JobPayment?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("History")
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let payment { Chip(label: payment.displayName, tone: payment.status == "paid" ? .mint : .grey) }
            }
            ForEach(entries.reversed()) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(entry.seq == entries.last?.seq ? BountyColor.lavender : BountyColor.greyBack)
                        .frame(width: 8, height: 8)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.label)
                            .bountyType(.subhead)
                            .foregroundStyle(BountyColor.inkPrimary)
                        Text("\(entry.at.formatted(date: .abbreviated, time: .shortened))\(Self.actorText(entry.actor).map { " · \($0)" } ?? "")")
                            .bountyType(.caption)
                            .foregroundStyle(BountyColor.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(16)
        .borderedCard()
    }

    static func actorText(_ actor: String?) -> String? {
        switch actor {
        case "you": "You"
        case "poster": "Poster"
        case "worker": "Worker"
        case "admin": "Admin"
        case "platform": "Bounty"
        default: nil
        }
    }
}

/// Shown when the job can't be found or loaded (plan step 10), with a way to try again.
private struct JobUnavailable: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store
    @State private var isRetrying = false

    var body: some View {
        VStack(spacing: 12) {
            if isRetrying || (store.errorMessage == nil && store.isLoading) {
                ProgressView()
                    .padding(.vertical, 24)
            } else {
                StickerView(sticker: .shield, size: 64)
                Text("Couldn’t load this job")
                    .bountyType(.headline)
                    .foregroundStyle(BountyColor.inkPrimary)
                Text(store.errorMessage ?? "It may have been removed, or the connection dropped.")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .multilineTextAlignment(.center)
                PillButton(title: "Try again", style: .secondary) {
                    Task {
                        isRetrying = true
                        defer { isRetrying = false }
                        if let id = router.posterJobId { await store.refresh(jobId: id) }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }
}

/// The six steps from plan feature 11, in the horizontal style of Alan's worker timeline:
/// green for done, a wide yellow capsule for the current step.
private struct StatusTimeline: View {
    let job: PostedJob

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 4) {
                ForEach(TimelineStep.allCases, id: \.self) { step in
                    let phase = status(of: step)
                    VStack(spacing: 5) {
                        Capsule()
                            .fill(color(for: phase))
                            .frame(width: phase == .active ? 34 : 14, height: 14)
                        Text(shortTitle(step))
                            .bountyType(.caption)
                            .foregroundStyle(phase == .todo ? BountyColor.inkTertiary : BountyColor.inkPrimary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(phase == .done ? "Done" : phase == .active ? "Current step" : "Not yet")
                }
            }
            if let detail = currentDetail {
                Text(detail)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
    }

    private func status(of step: TimelineStep) -> StepStatus {
        guard let current = job.status.timelineStep else { return .todo }
        if job.status == .released || step.rawValue < current.rawValue { return .done }
        return step == current ? .active : .todo
    }

    private func shortTitle(_ step: TimelineStep) -> String {
        switch step {
        case .funded: "Funded"
        case .offered: "Offered"
        case .accepted: "Accepted"
        case .inProgress: "Working"
        case .submitted: "Review"
        case .paid: "Paid"
        }
    }

    private func color(for status: StepStatus) -> Color {
        switch status {
        case .done: BountyColor.green
        case .active: BountyColor.yellow
        case .todo: BountyColor.pill
        }
    }

    /// A short line saying what's happening at the current step.
    private var currentDetail: String? {
        switch job.status {
        case .funded: "Your payment is held in escrow."
        case .offered: "Twins are matching it with nearby workers."
        case .accepted: "\(job.worker?.name ?? "A worker") accepted the job."
        case .inProgress: "\(job.worker?.name ?? "The worker") is on it."
        case .submitted: "Proof is in. The AI is checking it."
        case .inReview: "The AI checked the proof. Waiting for you."
        case .disputed: "Under dispute."
        case .draft, .released, .refunded: nil
        }
    }
}

#Preview {
    PostedJobDetailView()
        .environment(AppRouter())
        .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}

/// What's at risk in this escrow, the way a lender would put it: the chance of a loss, how much of the
/// money that loss would take, and the expected loss, plus the worker's trust behind those numbers.
private struct EscrowRiskCard: View {
    let risk: EscrowRisk

    private func percent(_ x: Double) -> String { x.formatted(.percent.precision(.fractionLength(x < 0.1 ? 1 : 0))) }

    private var tone: ChipTone {
        switch risk.tier {
        case "A", "B": .mint
        case "C": .cream
        default: .coral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Escrow risk", icon: .shieldCheck)
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
                Spacer()
                Chip(label: "Tier \(risk.tier)", tone: tone)
            }
            Text("Expected loss \(risk.expectedLoss.formatted(.currency(code: "USD"))) on \(risk.exposure.formatted(.currency(code: "USD"))): \(percent(risk.probabilityOfLoss)) chance \u{00D7} \(percent(risk.lossGivenDefault)) of the escrow.")
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkSecondary)
            if let worker = risk.worker {
                Text("Worker trust \(percent(worker.trust)) (at least \(percent(worker.conservative)) with 95% confidence, from \(worker.ratedJobs.formatted()) weighted jobs).")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            Text(risk.rail == "usdc" ? "Paid in USDC: a release can\u{2019}t be charged back." : "Paid by card: refunds keep the processing fee, and payouts can be charged back.")
                .bountyType(.caption)
                .foregroundStyle(BountyColor.inkTertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .borderedCard(radius: BountyRadius.row)
    }
}
