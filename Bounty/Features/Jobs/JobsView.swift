import SwiftUI

enum JobsSegment: Hashable {
    case working, posted, done
}

// MARK: - 16 Jobs

struct JobsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store

    private func jobs(for segment: JobsSegment) -> [Job] {
        switch segment {
        case .working: SampleJobs.working
        case .posted: store.sortedJobs
        case .done: SampleJobs.working.filter { $0.status == .released }
        }
    }

    var body: some View {
        @Bindable var router = router
        BountyScreen {
            ScreenTitle(title: "Jobs") {
                IconButton(icon: .sliders, label: "Filters") {}
            }
            .entrance(.top)

            SegmentedPill(
                options: [(JobsSegment.working, "Working"), (.posted, "Posted"), (.done, "Done")],
                selection: $router.jobsSegment
            )
            .entrance(.top)

            let visible = jobs(for: router.jobsSegment)
            VStack(spacing: 16) {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, job in
                    JobCard(job: job, isPosted: router.jobsSegment == .posted) { open(job) }
                        .entrance(index == 0 ? .top : .rest(min(index - 1, 4)))
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .animation(Motion.enterRest, value: router.jobsSegment)

            if visible.isEmpty {
                Text(router.jobsSegment == .posted ? "Jobs you post show up here." : "Nothing here yet.")
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
            }
        }
        .task(id: router.jobsSegment) {
            // Keep the Posted list live while it's on screen. Fine for the demo; push alerts
            // take over once the backend sends them.
            guard router.jobsSegment == .posted else { return }
            while !Task.isCancelled {
                await store.loadJobs()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func open(_ job: Job) {
        if router.jobsSegment == .posted {
            router.open(job.status == .inReview ? .reviewProof : .postedJob, posterJob: job.id)
            return
        }
        switch job.status {
        case .offered: router.open(.offer)
        case .accepted, .inProgress: router.open(.jobDetail)
        default: break
        }
    }
}

private struct JobCard: View {
    let job: Job
    let isPosted: Bool
    let action: () -> Void

    private var detail: String {
        guard isPosted else { return "\(job.distanceText) · \(job.deadlineText)" }
        switch job.status {
        case .draft: return "Not live yet · fund it to post"
        case .inReview, .submitted: return "\(job.worker?.name ?? "Worker") · submitted proof"
        case .accepted, .inProgress, .disputed, .released: return "\(job.worker?.name ?? "Worker") · Due \(job.deadlineText)"
        case .funded, .offered: return "Finding a worker · Due \(job.deadlineText)"
        case .refunded: return "Refunded"
        }
    }

    private var statusLabel: String {
        guard isPosted else { return job.status.displayName }
        switch job.status {
        case .inReview: return "Needs your review"
        case .draft: return "Finish posting"
        default: return job.status.displayName
        }
    }

    private var statusTone: ChipTone {
        isPosted && job.status.needsPosterAction ? .yellow : job.status.chipTone
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                StickerTile(sticker: job.sticker, background: job.tileColor, size: 56, stickerSize: 46, radius: 17)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title)
                        .bountyType(.bodyStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                    Text(detail)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                    Chip(label: statusLabel, tone: statusTone)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                Text(job.payShort)
                    .bountyType(.moneyM)
                    .foregroundStyle(BountyColor.inkPrimary)
            }
            .padding(14)
            .borderedCard(radius: 22)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - 15 Review proof

/// Step 8: the poster reviews submitted work (plan features 26, 30, 32). Before and after photos,
/// the AI's grade for each requirement, and a countdown to automatic release. Disputing requires
/// naming the requirement that wasn't met.
struct ReviewProofView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store

    @State private var expandedId: ChecklistItem.ID?
    @State private var isApproving = false
    @State private var isDisputing = false
    @State private var errorMessage: String?

    private var job: Job? { store.job(router.posterJobId) }

    var body: some View {
        BountyScreen(spacing: 14) {
            NavRow(leadingAction: router.back) {
                if let job {
                    Chip(
                        label: job.status == .inReview ? "Needs your review" : job.status.displayName,
                        tone: job.status == .inReview ? .yellow : job.status.chipTone
                    )
                }
            } trailing: {
                EmptyView()
            }
            .entrance(.top)

            if let job {
                Text("Review \(workerFirstName(job))’s work")
                    .bountyType(.title)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .entrance(.top)

                HStack(spacing: 11) {
                    ProofPhoto(url: job.posterPhotos.first, fallbackAsset: "before-photo", label: "Before")
                    ProofPhoto(url: firstProofPhoto(job), fallbackAsset: "after-photo", label: "After")
                }
                .entrance(.top)

                AISummary(job: job)
                    .entrance(.rest(0))

                VStack(spacing: 2) {
                    ForEach(job.checklist) { item in
                        CheckRow(
                            item: item,
                            proof: job.proof?.item(for: item),
                            verdict: job.verdict(for: item),
                            isExpanded: expandedId == item.id
                        ) {
                            withAnimation(Motion.press) {
                                expandedId = expandedId == item.id ? nil : item.id
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .borderedCard()
                .entrance(.rest(1))

                if job.status == .inReview, let deadline = job.reviewDeadline {
                    HStack(spacing: 8) {
                        IconGlyph(icon: .timer, size: 16)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text("Approves on its own in \(remaining(until: deadline, at: context.date)) if you don’t respond")
                                .bountyType(.footnote)
                                .monospacedDigit()
                        }
                    }
                    .foregroundStyle(BountyColor.inkSecondary)
                    .entrance(.rest(2))
                } else if let outcome = outcome(for: job) {
                    HStack(spacing: 10) {
                        IconGlyph(icon: job.status == .disputed ? .flag : .shieldCheck, size: 20)
                        Text(outcome)
                            .bountyType(.subheadStrong)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(job.status == .disputed ? BountyColor.creamInk : BountyColor.mintInk)
                    .padding(14)
                    .tintedPanel(job.status == .disputed ? BountyColor.cream : BountyColor.mint, radius: BountyRadius.row)
                }
            }
        } bottom: {
            if let job, job.status == .inReview {
                VStack(spacing: 12) {
                    PillButton(title: isApproving ? "Approving…" : "Approve and pay \(job.payShort)", icon: .check) {
                        Task { await approve(job) }
                    }
                    .disabled(isApproving)
                    PillButton(title: "Dispute an item", icon: .flag, style: .secondary) {
                        isDisputing = true
                    }
                    .disabled(isApproving)
                }
            } else {
                PillButton(title: "Done") {
                    router.jobsSegment = .posted
                    router.finish(on: .jobs)
                }
            }
        }
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
            guard let jobId = router.posterJobId else { return }
            while !Task.isCancelled {
                await store.refresh(jobId: jobId)
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func workerFirstName(_ job: Job) -> String {
        job.worker?.name.split(separator: " ").first.map(String.init) ?? "the worker"
    }

    private func firstProofPhoto(_ job: Job) -> URL? {
        job.proof?.items.lazy.compactMap(\.photoURLs.first).first
    }

    private func outcome(for job: Job) -> String? {
        switch job.status {
        case .released: "Approved. \(job.worker?.name ?? "The worker") was paid \(job.payShort)."
        case .disputed: "Disputed. The AI takes a second look, then a person decides."
        default: nil
        }
    }

    private func remaining(until deadline: Date, at date: Date) -> String {
        let seconds = max(0, Int(deadline.timeIntervalSince(date)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
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

/// A before or after photo. Uses the real upload when there is one, else the design's art.
private struct ProofPhoto: View {
    let url: URL?
    let fallbackAsset: String
    let label: String

    var body: some View {
        // A fixed-size frame with the photo as an overlay, so a wide photo can't widen the row.
        Color.clear
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .overlay {
                if let url {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(fallbackAsset).resizable()
                        }
                    }
                } else {
                    Image(fallbackAsset).resizable()
                }
            }
            .overlay(alignment: .topLeading) {
                Chip(label: label, tone: .dark).padding(10)
            }
        .clipShape(RoundedRectangle(cornerRadius: BountyRadius.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) photo")
    }
}

/// The AI's overall read: green when everything passed confidently, cream when something
/// deserves a closer look.
private struct AISummary: View {
    let job: Job

    private var passed: Int { job.verdicts.filter(\.pass).count }
    private var needsALook: Bool {
        job.verdicts.contains { !$0.pass || $0.confidence < Verdict.reviewThreshold }
    }
    private var average: Double {
        guard !job.verdicts.isEmpty else { return 0 }
        return job.verdicts.map(\.confidence).reduce(0, +) / Double(job.verdicts.count)
    }

    var body: some View {
        HStack(spacing: 10) {
            IconGlyph(icon: needsALook ? .scanFace : .shieldCheck, size: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("AI check: \(passed) of \(job.checklist.count) passed")
                    .bountyType(.bodyStrong)
                if needsALook {
                    Text("Tap an item to see why it’s worth a look.")
                        .bountyType(.footnote)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !job.verdicts.isEmpty {
                Text("\(average.formatted(.percent.precision(.fractionLength(0)))) avg")
                    .bountyType(.subheadStrong)
            }
        }
        .foregroundStyle(needsALook ? BountyColor.creamInk : BountyColor.mintInk)
        .padding(14)
        .tintedPanel(needsALook ? BountyColor.cream : BountyColor.mint, radius: BountyRadius.row)
    }
}

/// One requirement with its proof and grade, e.g. "Clippings bagged · 1 photo · 98%".
/// Tapping shows the AI's one-line explanation.
private struct CheckRow: View {
    let item: ChecklistItem
    let proof: ProofItem?
    let verdict: Verdict?
    let isExpanded: Bool
    let onTap: () -> Void

    private var needsALook: Bool {
        guard let verdict else { return true }
        return !verdict.pass || verdict.confidence < Verdict.reviewThreshold
    }

    private var evidence: String {
        switch item.evidenceType {
        case .photo:
            let count = proof?.photoURLs.count ?? 0
            return count == 1 ? "1 photo" : "\(count) photos"
        case .checkIn:
            return proof?.checkedInAt.map { "GPS · \($0.formatted(date: .omitted, time: .shortened))" } ?? "No check-in"
        case .link, .file:
            return proof?.link == nil ? "Nothing sent" : "Link"
        }
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    badge
                    Text(item.text)
                        .bountyType(.subheadStrong)
                        .foregroundStyle(BountyColor.inkPrimary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(verdict.map { "\(evidence) · \($0.confidence.formatted(.percent.precision(.fractionLength(0))))" } ?? evidence)
                        .bountyType(.footnote)
                        .foregroundStyle(needsALook ? BountyColor.creamInk : BountyColor.inkSecondary)
                }
                if isExpanded, let verdict {
                    Text(verdict.explanation)
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                        .padding(.leading, 40)
                        .transition(.opacity)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(verdict == nil ? "" : "Shows the AI's explanation")
    }

    @ViewBuilder
    private var badge: some View {
        if let verdict, !verdict.pass {
            IconGlyph(icon: .x, size: 16, weight: .bold)
                .foregroundStyle(BountyColor.inkInverse)
                .frame(width: 28, height: 28)
                .background(BountyColor.red, in: Circle())
                .accessibilityLabel("Not met")
        } else {
            StatusBadge(status: needsALook ? .active : .done)
                .accessibilityLabel(needsALook ? "Likely met, worth a look" : "Met")
        }
    }
}

#Preview("Jobs") {
    JobsView()
        .environment(AppRouter())
        .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
