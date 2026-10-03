import SwiftUI

/// A job the poster posted, followed live (plan step 6, feature 11). Shows where the job is on
/// the six-step timeline, who's doing it, and what the poster should do next. The screen polls
/// while open, so status changes from the backend appear on their own.
struct PostedJobDetailView: View {
    @Environment(PosterStore.self) private var store
    let jobId: String

    @State private var isFunding = false
    @State private var isApproving = false
    @State private var errorMessage: String?

    private var job: Job? { store.jobs.first { $0.id == jobId } }

    var body: some View {
        List {
            if let job {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.payText)
                            .font(.largeTitle.bold())
                        Text(job.title)
                            .font(.title3.weight(.semibold))
                        Text("\(job.isRemote ? "Remote" : job.location?.address ?? "") · Due \(job.deadlineText)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
                }

                NextActionSection(
                    job: job,
                    isApproving: isApproving,
                    onFund: { isFunding = true },
                    onApprove: { Task { await approve(job) } }
                )

                if job.status != .draft {
                    Section("Progress") {
                        StatusTimeline(job: job)
                    }
                }

                if let worker = job.worker {
                    Section("Worker") {
                        HStack {
                            Label(worker.name, systemImage: "person.crop.circle.fill")
                            Spacer()
                            if let rating = worker.rating {
                                Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("New worker")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("What counts as done") {
                    ForEach(job.checklist) { item in
                        ChecklistStatusRow(item: item, verdict: job.verdict(for: item))
                    }
                }
            } else {
                ContentUnavailableView("Job not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle(job?.status.displayName ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $isFunding) {
            if let job {
                FundJobView(job: job) { _ in isFunding = false }
            }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
        .task {
            // Poll while the screen is open so status changes appear live. Fine for the demo;
            // push notifications (step 7) take over once they're wired up.
            while !Task.isCancelled {
                await store.refresh(jobId: jobId)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func approve(_ job: Job) async {
        isApproving = true
        defer { isApproving = false }
        do {
            try await store.approve(job)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Next action

/// The one thing the poster should know or do right now, placed above the timeline.
private struct NextActionSection: View {
    let job: Job
    let isApproving: Bool
    let onFund: () -> Void
    let onApprove: () -> Void

    var body: some View {
        switch job.status {
        case .draft:
            Section {
                Text("This job isn't live yet. Workers see it once it's funded.")
                Button("Fund the job", systemImage: "lock.fill", action: onFund)
                    .font(.headline)
            }
        case .inReview:
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The work is in. Your turn.")
                        .font(.headline)
                    if let deadline = job.reviewDeadline, deadline > .now {
                        Text("Payment releases automatically in \(Text(deadline, style: .timer))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Button {
                    onApprove()
                } label: {
                    HStack {
                        if isApproving { ProgressView() }
                        Text("Approve and pay \(job.payText)")
                    }
                    .font(.headline)
                }
                .disabled(isApproving)
            } footer: {
                Text("Check the AI's grades below first. The full review screen is coming next.")
            }
        case .disputed:
            Section {
                Label("You disputed this job. The AI takes a second look, then a person decides.", systemImage: "exclamationmark.bubble")
            }
        case .released:
            Section {
                Label("Done. \(job.worker?.name ?? "The worker") was paid \(job.payText).", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(BountyTheme.success)
            }
        case .refunded:
            Section {
                Label("Refunded. No one finished this job by the deadline, so your \(job.payText) came back to you.", systemImage: "arrow.uturn.backward.circle")
            }
        case .funded, .offered, .accepted, .inProgress, .submitted:
            EmptyView()
        }
    }
}

// MARK: - Timeline

/// The six steps from plan feature 11, done ones checked and the current one highlighted.
private struct StatusTimeline: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(TimelineStep.allCases, id: \.self) { step in
                TimelineRow(
                    step: step,
                    state: state(of: step),
                    detail: detail(for: step),
                    isLast: step == TimelineStep.allCases.last
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func state(of step: TimelineStep) -> TimelineRow.Phase {
        guard let current = job.status.timelineStep else { return .upcoming }
        if job.status == .released || step.rawValue < current.rawValue { return .done }
        return step == current ? .current : .upcoming
    }

    /// A short line under the current step saying what's happening.
    private func detail(for step: TimelineStep) -> String? {
        guard state(of: step) == .current else { return nil }
        switch job.status {
        case .funded: return "Your payment is held in escrow."
        case .offered: return "Twins are matching it with nearby workers."
        case .accepted: return "\(job.worker?.name ?? "A worker") accepted the job."
        case .inProgress: return "\(job.worker?.name ?? "The worker") is on it."
        case .submitted: return "Proof is in. The AI is checking it."
        case .inReview: return "The AI checked the proof. Waiting for you."
        case .disputed: return "Under dispute."
        case .draft, .released, .refunded: return nil
        }
    }
}

private struct TimelineRow: View {
    enum Phase { case done, current, upcoming }

    let step: TimelineStep
    let state: Phase
    let detail: String?
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                marker
                if !isLast {
                    Rectangle()
                        .fill(state == .done ? BountyTheme.accent : Color.secondary.opacity(0.3))
                        .frame(width: 2)
                        .frame(minHeight: 22)
                }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(state == .current ? .semibold : .regular))
                    .foregroundStyle(state == .upcoming ? .secondary : .primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, isLast ? 0 : 10)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .done ? "Done" : state == .current ? "Current step" : "Not yet")
    }

    @ViewBuilder
    private var marker: some View {
        switch state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(BountyTheme.accent)
        case .current:
            Image(systemName: "circle.inset.filled")
                .foregroundStyle(BountyTheme.accent)
                .symbolEffect(.pulse)
        case .upcoming:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Checklist

/// One requirement with its AI grade once the proof is in.
private struct ChecklistStatusRow: View {
    let item: ChecklistItem
    let verdict: Verdict?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text)
            if let verdict {
                Label(
                    "\(verdict.pass ? "Pass" : "Fail") · \(verdict.confidence.formatted(.percent.precision(.fractionLength(0)))) confident",
                    systemImage: verdict.pass ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(verdict.pass ? BountyTheme.success : BountyTheme.warning)
            } else {
                Label(item.evidenceSummary, systemImage: item.evidenceType.symbolName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        PostedJobDetailView(jobId: "job_lawn")
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
