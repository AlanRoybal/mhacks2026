import SwiftUI

enum JobsSegment: Hashable {
    case working, posted, done
}

// MARK: - 16 Jobs

struct JobsView: View {
    @Environment(AppRouter.self) private var router
    @Environment(AppServices.self) private var services
    @Environment(MarketplaceStore.self) private var marketplace
    // Jobs funded through Stripe checkout (real data) come before the sample cards.
    @EnvironmentObject private var postedJobs: PostedJobsStore
    @EnvironmentObject private var workerPayments: WorkerPayments
    @State private var selectedJob: Job?
    // The poster's jobs from the backend (GET /jobs/mine), or sample jobs when it isn't running.
    @Environment(PosterStore.self) private var posterStore

    /// Paid or refunded: nothing left to do on either side, so the job moves to Done.
    private static let finished: Set<JobStatus> = [.paid, .refunded]

    private func jobs(for segment: JobsSegment) -> [Job] {
        let workerJobs = marketplace.workingJobs.map(\.displayJob) + workerPayments.jobs
        // Checkout jobs the backend hasn't listed yet; normally they all come through `posterStore`.
        let checkoutJobs = postedJobs.fundedJobs.map(\.job).filter { posterStore.job($0.id) == nil }
        return switch segment {
        case .working: workerJobs.filter { !Self.finished.contains($0.status) }
        case .posted: checkoutJobs.filter { !Self.finished.contains($0.status) }
        case .done: (workerJobs + checkoutJobs).filter { Self.finished.contains($0.status) }
        }
    }

    /// The backend's posted jobs for a segment: open ones under Posted, paid or refunded ones under Done.
    private func posterJobs(for segment: JobsSegment) -> [PostedJob] {
        switch segment {
        case .working: []
        case .posted: posterStore.sortedJobs.filter { !$0.status.isTerminal }
        case .done: posterStore.sortedJobs.filter(\.status.isTerminal)
        }
    }

    var body: some View {
        @Bindable var router = router
        BountyScreen(alwaysBounces: true) {
            ScreenTitle(title: "Jobs") { EmptyView() }
            .entrance(.top)

            SegmentedPill(
                options: [(JobsSegment.working, "Working"), (.posted, "Posted"), (.done, "Done")],
                selection: $router.jobsSegment
            )
            .entrance(.top)

            VStack(spacing: 16) {
                ForEach(Array(posterJobs(for: router.jobsSegment).enumerated()), id: \.element.id) { index, job in
                    PostedJobCard(job: job) {
                        router.open(job.status == .inReview ? .reviewProof : .postedJob, posterJob: job.id)
                    }
                    .entrance(index == 0 ? .top : .rest(min(index - 1, 4)))
                    .transition(.opacity.combined(with: .offset(y: 12)))
                }
                ForEach(Array(jobs(for: router.jobsSegment).enumerated()), id: \.element.id) { index, job in
                    JobCard(job: job, isPosted: router.jobsSegment == .posted) { open(job) }
                        .entrance(index == 0 ? .top : .rest(index - 1))
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .animation(Motion.enterRest, value: router.jobsSegment)

            if router.jobsSegment == .posted {
                PostedListStatus(hasOpenJobs: !posterJobs(for: .posted).isEmpty || !jobs(for: .posted).isEmpty)
            } else if router.jobsSegment == .done, posterJobs(for: .done).isEmpty, jobs(for: .done).isEmpty {
                EmptyJobsCard(title: "Nothing done yet", message: "Jobs you finish or post land here once they\u{2019}re paid or refunded.")
            }

            if let error = posterStore.errorMessage, router.jobsSegment != .working {
                Text("Couldn\u{2019}t load your posted jobs: \(error) Pull down to try again.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            }
        }
        .sheet(item: $selectedJob) { job in NavigationStack { FundedJobDetailView(job: job) } }
        .task { await reload() }
        .refreshable { await reload() }
        .task(id: router.jobsSegment) {
            // Keep the Posted list live while it's on screen; push alerts take over once wired up.
            guard router.jobsSegment == .posted else { return }
            while !Task.isCancelled {
                await posterStore.loadJobs()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func reload() async {
        await postedJobs.refresh()
        await workerPayments.refresh()
        await marketplace.refresh(api: services.api)
        await posterStore.loadJobs()
    }

    private func open(_ job: Job) {
        if marketplace.workingJobs.contains(where: { $0.id == job.id }) {
            router.open(.jobDetail, workerJob: job.id)
        } else {
            selectedJob = job
        }
    }

}

/// A segment with nothing in it.
private struct EmptyJobsCard: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .bountyType(.headline)
                .foregroundStyle(BountyColor.inkPrimary)
            Text(message)
                .bountyType(.subhead)
                .foregroundStyle(BountyColor.inkSecondary)
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: .infinity)
        .borderedCard()
    }
}

/// Plan step 10: what the Posted list says while loading, after an error, or with nothing posted.
private struct PostedListStatus: View {
    let hasOpenJobs: Bool
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store

    private var isEmpty: Bool { !hasOpenJobs }

    var body: some View {
        if let message = store.errorMessage {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    IconGlyph(icon: .refresh, size: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Couldn’t refresh your jobs")
                            .bountyType(.bodyStrong)
                        Text(message)
                            .bountyType(.footnote)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .foregroundStyle(BountyColor.creamInk)
                PillButton(title: store.isLoading ? "Trying again…" : "Try again", style: .secondary) {
                    Task { await store.loadJobs() }
                }
                .disabled(store.isLoading)
            }
            .padding(14)
            .tintedPanel(BountyColor.cream, radius: BountyRadius.row)
        } else if isEmpty && !store.hasLoaded {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading your jobs…")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else if isEmpty && !store.jobs.isEmpty {
            EmptyJobsCard(title: "No open posts", message: "Your finished jobs are under Done. Post another and your twin finds someone nearby.")
        } else if isEmpty {
            VStack(spacing: 12) {
                StickerView(sticker: .poster, size: 72)
                Text("Nothing posted yet")
                    .bountyType(.headline)
                    .foregroundStyle(BountyColor.inkPrimary)
                Text("Post a job and your twin finds someone nearby. You’ll follow it here.")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
                    .multilineTextAlignment(.center)
                PillButton(title: "Post a job", icon: .plus) { router.select(.post) }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .borderedCard()
        }
    }
}

private struct JobCard: View {
    let job: Job
    let isPosted: Bool
    let action: () -> Void

    private var detail: String {
        "\(job.location) · \(job.deadline)"
    }

    private var statusLabel: String {
        job.status.rawValue
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
                    Chip(label: statusLabel, tone: job.status.chipTone)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                Text(job.displayPay)
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

/// The live review for one of the poster's jobs. If the job isn't loaded yet, it loads it; if that
/// fails, it says so.
struct ReviewProofView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var posterStore
    @State private var loading = true

    var body: some View {
        if posterStore.job(router.posterJobId) != nil {
            LiveReviewProofView()
        } else {
            BountyScreen {
                NavRow(leadingAction: router.back) { Text("Review").bountyType(.bodyStrong) } trailing: { EmptyView() }
                if loading {
                    ProgressView("Loading the job\u{2026}")
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else {
                    Text(posterStore.errorMessage ?? "This job couldn\u{2019}t be found.")
                        .bountyType(.body)
                        .foregroundStyle(BountyColor.inkSecondary)
                    PillButton(title: "Try again", icon: .refresh, style: .secondary) { Task { await load() } }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        if let id = router.posterJobId { await posterStore.refresh(jobId: id) }
        loading = false
    }
}

#Preview("Jobs") {
    JobsView()
        .environment(AppRouter())
        .environment(AppServices())
        .environment(MarketplaceStore())
        .environmentObject(WorkerPayments())
        .environmentObject(PostedJobsStore())
        .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}

#Preview("Review proof") {
    ReviewProofView()
        .environment(AppRouter())
        .environmentObject(WorkerPayments())
        .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}

struct FundedJobDetailView: View {
    @EnvironmentObject private var postedJobs: PostedJobsStore
    @EnvironmentObject private var workerPayments: WorkerPayments
    @State private var refundBusy = false
    @State private var refundMessage: String?
    let job: Job
    private var currentStatus: JobStatus {
        workerPayments.jobs.first(where: { $0.id == job.id })?.status
            ?? postedJobs.fundedJobs.first(where: { $0.id.uuidString.lowercased() == job.id }).map { JobStatus.api($0.status) } ?? job.status
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.displayPay)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text(job.title)
                        .font(.title2.bold())
                    Label(currentStatus.rawValue, systemImage: "clock.fill")
                        .foregroundStyle(BountyColor.greenInk)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Job details")
                        .font(.headline)
                    Text(postedJobs.fundedJobs.first { $0.id.uuidString.lowercased() == job.id }?.details ?? job.location)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .borderedCard()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Proof")
                        .font(.headline)
                    Label("Photos or a short video of the finished work, taken in the Bounty app", systemImage: "camera")
                    Label("Due \(job.deadline)", systemImage: "clock")
                }
                .padding(16)
                .borderedCard()

                if let posted = postedJobs.fundedJobs.first(where: { $0.id.uuidString.lowercased() == job.id }), posted.fundingRail == "usdc",
                   !["released", "refunded"].contains(posted.status),
                   (posted.deadlineDate ?? .distantFuture) <= Date() {
                    Button(refundBusy ? "Confirming refund…" : "Refund expired job") { Task { await refund(posted) } }
                        .buttonStyle(.bordered)
                        .disabled(refundBusy)
                }
                if let refundMessage { Text(refundMessage).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
    }
    @MainActor
    private func refund(_ posted: FundedJob) async {
        refundBusy = true; refundMessage = nil
        defer { refundBusy = false }
        do {
            let api = PaymentAPI(baseURLKey: "BountySettlementsBaseURL")
            let transaction: CryptoTransaction = try await api.request(path: "crypto/jobs/\(posted.id.uuidString.lowercased())/refund-transaction", method: "GET")
            let wallet = BountyWallet.shared
            try await wallet.connect()
            guard wallet.address?.lowercased() == posted.posterWallet?.lowercased() else { throw PaymentAPIError(message: "Connect the wallet that funded this job.") }
            let hash = try await wallet.send(to: transaction.to, data: transaction.data)
            let confirmed: FundedJob = try await api.request(path: "crypto/jobs/\(posted.id.uuidString.lowercased())/confirm", method: "POST",
                body: JSONEncoder().encode(["transactionHash": hash]))
            postedJobs.record(confirmed)
            refundMessage = confirmed.status == "refunded" ? "USDC refunded to your wallet." : "Refund is still being confirmed."
        } catch { refundMessage = error.localizedDescription }
    }
}
