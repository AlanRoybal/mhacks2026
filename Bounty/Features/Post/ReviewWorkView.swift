import SwiftUI

/// Step 8: the poster reviews submitted work (plan features 26, 30, 32). Each requirement shows
/// the worker's proof next to the AI's grade, so approving takes seconds. Disputing requires
/// naming the requirement that wasn't met. If the poster does nothing, the server releases the
/// payment when the review window closes.
struct ReviewWorkView: View {
    @Environment(PosterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let jobId: String

    @State private var isApproving = false
    @State private var isDisputing = false
    @State private var errorMessage: String?

    private var job: Job? { store.jobs.first { $0.id == jobId } }

    var body: some View {
        Group {
            if let job {
                content(for: job)
            } else {
                ContentUnavailableView("Job not found", systemImage: "questionmark.folder")
            }
        }
        .navigationTitle("Review the work")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isDisputing) {
            if let job {
                DisputeSheet(job: job) { item, note in
                    try await store.dispute(job, item: item, note: note)
                }
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
            // Keep the job fresh, so the screen notices if the window closes and payment releases.
            while !Task.isCancelled {
                await store.refresh(jobId: jobId)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    @ViewBuilder
    private func content(for job: Job) -> some View {
        List {
            Section {
                SummaryHeader(job: job)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
            }

            ForEach(Array(job.checklist.enumerated()), id: \.element.id) { index, item in
                Section {
                    RequirementReviewCard(
                        item: item,
                        proof: job.proof?.item(for: item),
                        verdict: job.verdict(for: item),
                        posterPhotos: beforePhotos(for: item, in: job)
                    )
                } header: {
                    Text("Requirement \(index + 1) of \(job.checklist.count)")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if job.status == .inReview {
                DecisionBar(
                    job: job,
                    isApproving: isApproving,
                    onApprove: { Task { await approve(job) } },
                    onDispute: { isDisputing = true }
                )
            } else {
                OutcomeBar(job: job) { dismiss() }
            }
        }
    }

    /// The poster's own "before" photos, shown above the worker's "after" photos on the first
    /// photo requirement, so the change is visible at a glance.
    private func beforePhotos(for item: ChecklistItem, in job: Job) -> [URL] {
        guard !job.posterPhotos.isEmpty,
              item.id == job.checklist.first(where: { $0.evidenceType == .photo })?.id
        else { return [] }
        return job.posterPhotos
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

// MARK: - Header

/// The AI's overall read, with the auto-release countdown.
private struct SummaryHeader: View {
    let job: Job

    private var passed: Int { job.verdicts.filter(\.pass).count }
    private var needsALook: Int { job.verdicts.filter { !$0.pass || $0.confidence < Verdict.reviewThreshold }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.title)
                .font(.title2.bold())
            if let worker = job.worker {
                Text("Submitted by \(worker.name)\(job.proof.map { " · \($0.submittedAt.formatted(.relative(presentation: .named)))" } ?? "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Label(
                "AI checked \(job.checklist.count) requirements: \(passed) passed" + (needsALook > 0 ? ", \(needsALook) worth a closer look." : "."),
                systemImage: "sparkles"
            )
            .font(.subheadline)
            .foregroundStyle(BountyTheme.accent)

            if job.status == .inReview, let deadline = job.reviewDeadline, deadline > .now {
                Text("No response needed: payment releases automatically in \(Text(deadline, style: .timer)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - One requirement

private struct RequirementReviewCard: View {
    let item: ChecklistItem
    let proof: ProofItem?
    let verdict: Verdict?
    let posterPhotos: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.text)
                .font(.headline)

            evidence

            if let verdict {
                VerdictView(verdict: verdict)
            } else {
                Label("Not graded yet", systemImage: "hourglass")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var evidence: some View {
        switch item.evidenceType {
        case .photo:
            if let photos = proof?.photoURLs, !photos.isEmpty {
                if posterPhotos.isEmpty {
                    PhotoStrip(urls: photos)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Before (yours)").font(.caption).foregroundStyle(.secondary)
                        PhotoStrip(urls: posterPhotos)
                        Text("After (worker's)").font(.caption).foregroundStyle(.secondary)
                        PhotoStrip(urls: photos)
                    }
                }
            } else {
                missing("No photos submitted")
            }
        case .checkIn:
            if let time = proof?.checkedInAt {
                Label("Checked in on site at \(time.formatted(date: .omitted, time: .shortened))", systemImage: "location.fill")
                    .font(.subheadline)
            } else {
                missing("No check-in recorded")
            }
        case .link, .file:
            if let link = proof?.link {
                Link(destination: link) {
                    Label(link.absoluteString, systemImage: item.evidenceType.symbolName)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            } else {
                missing("Nothing submitted")
            }
        }
    }

    private func missing(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.subheadline)
            .foregroundStyle(BountyTheme.warning)
    }
}

/// The AI's grade for one requirement. Low-confidence passes are flagged so the poster knows
/// where to look; the AI is evidence for a human decision, not the decision itself.
private struct VerdictView: View {
    let verdict: Verdict

    private var needsALook: Bool { !verdict.pass || verdict.confidence < Verdict.reviewThreshold }
    private var tint: Color {
        if !verdict.pass { return .red }
        return needsALook ? BountyTheme.warning : BountyTheme.success
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(
                    verdict.pass ? (needsALook ? "Likely met" : "Met") : "Not met",
                    systemImage: verdict.pass ? (needsALook ? "questionmark.circle.fill" : "checkmark.circle.fill") : "xmark.circle.fill"
                )
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(verdict.confidence.formatted(.percent.precision(.fractionLength(0)))) confident")
                    .font(.caption)
            }
            .foregroundStyle(tint)

            Text(verdict.explanation)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }
}

extension Verdict {
    /// Below this confidence, a pass is shown as "Likely met" and flagged for a closer look.
    static let reviewThreshold = 0.75
}

private struct PhotoStrip: View {
    let urls: [URL]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Image(systemName: "photo").foregroundStyle(.tertiary)
                        default:
                            ProgressView()
                        }
                    }
                    .frame(width: 140, height: 105)
                    .background(.quaternary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

// MARK: - Bottom bars

private struct DecisionBar: View {
    let job: Job
    let isApproving: Bool
    let onApprove: () -> Void
    let onDispute: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onApprove) {
                HStack {
                    if isApproving { ProgressView().tint(.white) }
                    Text("Approve and pay \(job.payText)")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isApproving)

            Button("Something's not right", action: onDispute)
                .font(.subheadline)
                .disabled(isApproving)
        }
        .padding()
        .background(.bar)
    }
}

/// Shown once a decision has been made, including when the window closed on its own.
private struct OutcomeBar: View {
    let job: Job
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Label(message, systemImage: job.status == .disputed ? "exclamationmark.bubble.fill" : "checkmark.seal.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(job.status == .disputed ? BountyTheme.warning : BountyTheme.success)
                .multilineTextAlignment(.center)
            Button("Done", action: onDone)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(.bar)
    }

    private var message: String {
        switch job.status {
        case .released: "Approved. \(job.worker?.name ?? "The worker") was paid \(job.payText)."
        case .disputed: "Disputed. The AI takes a second look, then a person decides."
        default: "This job is \(job.status.displayName.lowercased())."
        }
    }
}

// MARK: - Dispute

/// A dispute has to point at a specific requirement (plan feature 32), so it can be re-checked.
private struct DisputeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let job: Job
    let onSubmit: (ChecklistItem, String) async throws -> Void

    @State private var selectedId: ChecklistItem.ID?
    @State private var note = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Requirement", selection: $selectedId) {
                        Text("Choose one").tag(ChecklistItem.ID?.none)
                        ForEach(job.checklist) { item in
                            Text(item.text).tag(Optional(item.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Which requirement wasn't met?")
                }

                Section {
                    TextField("For example: the back of the lawn wasn't mowed", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($isTyping)
                } header: {
                    Text("What's wrong")
                } footer: {
                    Text("Payment stays on hold. The AI re-checks the proof for this requirement, then a person decides.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Dispute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await submit() } }
                        .disabled(selectedId == nil || note.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isTyping = false }
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() async {
        guard let item = job.checklist.first(where: { $0.id == selectedId }) else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await onSubmit(item, note.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        ReviewWorkView(jobId: "job_lawn")
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
