import SwiftUI

/// A job the poster posted, followed live (plan step 6, feature 11), in Alan's visual style.
/// Shows where the job is on the six-step timeline, who's doing it, and what to do next.
/// Polls while open, so status changes from the backend appear on their own.
struct PostedJobDetailView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store

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
                }

                // Step 9: paid or refunded jobs ask for a rating, then show the one given.
                RateWorkerCard(job: job)
                    .entrance(.rest(0))

                if job.status != .draft {
                    StatusTimeline(job: job)
                        .padding(16)
                        .borderedCard()
                        .entrance(.rest(1))
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
            }
        } bottom: {
            if let job {
                switch job.status {
                case .inReview:
                    PillButton(title: "Review the work", icon: .shieldCheck) {
                        router.open(.reviewProof, posterJob: job.id)
                    }
                default:
                    EmptyView()
                }
            }
        }
        .task {
            guard let jobId = router.posterJobId else { return }
            while !Task.isCancelled {
                await store.refresh(jobId: jobId)
                try? await Task.sleep(for: .seconds(2))
            }
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
            return StatusNote(text: "Refunded. No one finished by the deadline, so your \(job.payShort) came back.", sticker: .coins, fill: BountyColor.pill, ink: BountyColor.inkPill)
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
