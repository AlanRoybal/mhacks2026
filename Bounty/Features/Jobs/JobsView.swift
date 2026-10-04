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

    private func jobs(for segment: JobsSegment) -> [Job] {
        let workerJobs = marketplace.workingJobs.map(\.displayJob) + workerPayments.jobs
        return switch segment {
        case .working: workerJobs.filter { ![.paid, .refunded].contains($0.status) }
        // Checkout jobs the backend hasn't listed yet; normally they all come through `posterStore`.
        case .posted: postedJobs.fundedJobs.map(\.job).filter { posterStore.job($0.id) == nil }
        case .done: workerJobs.filter { [.paid, .refunded].contains($0.status) }
        }
    }

    var body: some View {
        @Bindable var router = router
        BountyScreen(alwaysBounces: true) {
            ScreenTitle(title: "Jobs") {
                IconButton(icon: .sliders, label: "Filters") {}
            }
            .entrance(.top)

            SegmentedPill(
                options: [(JobsSegment.working, "Working"), (.posted, "Posted"), (.done, "Done")],
                selection: $router.jobsSegment
            )
            .entrance(.top)

            VStack(spacing: 16) {
                if router.jobsSegment == .posted {
                    ForEach(Array(posterStore.sortedJobs.enumerated()), id: \.element.id) { index, job in
                        PostedJobCard(job: job) {
                            router.open(job.status == .inReview ? .reviewProof : .postedJob, posterJob: job.id)
                        }
                        .entrance(index == 0 ? .top : .rest(min(index - 1, 4)))
                        .transition(.opacity.combined(with: .offset(y: 12)))
                    }
                }
                ForEach(Array(jobs(for: router.jobsSegment).enumerated()), id: \.element.id) { index, job in
                    JobCard(job: job, isPosted: router.jobsSegment == .posted) { open(job) }
                        .entrance(index == 0 ? .top : .rest(index - 1))
                        .transition(.opacity.combined(with: .offset(y: 12)))
                }
            }
            .animation(Motion.enterRest, value: router.jobsSegment)

            if router.jobsSegment == .posted {
                PostedListStatus(hasCheckoutJobs: !jobs(for: .posted).isEmpty)
            }

            if router.jobsSegment == .posted && posterStore.isUsingSampleData {
                Text("Sample jobs. Start the backend (cd backend && npm run dev) to see the jobs you post.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkTertiary)
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
        if router.jobsSegment == .posted { await posterStore.loadJobs() }
    }

    private func open(_ job: Job) {
        if marketplace.workingJobs.contains(where: { $0.id == job.id }) {
            router.open(.jobDetail, workerJob: job.id)
        } else {
            selectedJob = job
        }
    }

}

/// Plan step 10: what the Posted list says while loading, after an error, or with nothing posted.
private struct PostedListStatus: View {
    let hasCheckoutJobs: Bool
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var store

    private var isEmpty: Bool { store.jobs.isEmpty && !hasCheckoutJobs }

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

/// Opens the live review for one of the poster's jobs, or the design's sample when there isn't one.
struct ReviewProofView: View {
    @Environment(AppRouter.self) private var router
    @Environment(PosterStore.self) private var posterStore

    var body: some View {
        if posterStore.job(router.posterJobId) != nil {
            LiveReviewProofView()
        } else {
            SampleReviewProofView()
        }
    }
}

private struct SampleReviewProofView: View {
    @Environment(AppRouter.self) private var router
    @State private var autoApproveAt = Date.now.addingTimeInterval(23 * 3600 + 41 * 60 + 10)

    private let checks = [
        ("Whole front lawn mowed", "4 photos · 96%"),
        ("Clippings bagged", "1 photo · 98%"),
        ("Sidewalk edges trimmed", "2 photos · 88%"),
        ("On site 2:02 – 2:51 PM", "GPS · verified")
    ]

    var body: some View {
        BountyScreen(spacing: 14) {
            NavRow(leadingAction: router.back) {
                Chip(label: "Needs your review", tone: .yellow)
            } trailing: {
                IconButton(icon: .ellipsis, label: "More") {}
            }
            .entrance(.top)

            Text("Review Jordan’s work")
                .bountyType(.title)
                .foregroundStyle(BountyColor.inkPrimary)
                .entrance(.top)

            HStack(spacing: 11) {
                proofPhoto("before-photo", label: "Before")
                proofPhoto("after-photo", label: "After")
            }
            .entrance(.top)

            HStack(spacing: 10) {
                IconGlyph(icon: .shieldCheck, size: 20)
                Text("AI check: 4 of 4 passed")
                    .bountyType(.bodyStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("94% avg")
                    .bountyType(.subheadStrong)
            }
            .foregroundStyle(BountyColor.mintInk)
            .padding(14)
            .tintedPanel(BountyColor.mint, radius: BountyRadius.row)
            .entrance(.rest(0))

            VStack(spacing: 2) {
                ForEach(checks, id: \.0) { check in
                    HStack(spacing: 12) {
                        StatusBadge(status: .done)
                        Text(check.0)
                            .bountyType(.subheadStrong)
                            .foregroundStyle(BountyColor.inkPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(check.1)
                            .bountyType(.footnote)
                            .foregroundStyle(BountyColor.inkSecondary)
                    }
                    .padding(.vertical, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .borderedCard()
            .entrance(.rest(1))

            HStack(spacing: 8) {
                IconGlyph(icon: .timer, size: 16)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("Approves on its own in \(remaining(at: context.date)) if you don’t respond")
                        .bountyType(.footnote)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(BountyColor.inkSecondary)
            .entrance(.rest(2))
        } bottom: {
            VStack(spacing: 12) {
                PillButton(title: "Approve and pay $40", icon: .check) { router.finish(on: .earnings) }
                PillButton(title: "Dispute an item", icon: .flag, style: .secondary) {}
            }
        }
    }

    private func proofPhoto(_ asset: String, label: String) -> some View {
        Image(asset)
            .resizable()
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .topLeading) {
                Chip(label: label, tone: .dark).padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: BountyRadius.row, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(label) photo")
    }

    private func remaining(at date: Date) -> String {
        let seconds = max(0, Int(autoApproveAt.timeIntervalSince(date)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
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
                    Text("Proof checklist")
                        .font(.headline)
                    Label("Show the finished work clearly", systemImage: "checkmark.circle")
                    Label("Include the one-time code", systemImage: "checkmark.circle")
                    Label("Submit before \(job.deadline)", systemImage: "checkmark.circle")
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
