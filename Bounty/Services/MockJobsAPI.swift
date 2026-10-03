import Foundation

/// An in-memory backend for building the poster screens before the real one exists.
/// It starts with one sample job in each interesting status, and it plays a newly funded job
/// forward through the state machine so the timeline and review screens can be tested live.
actor MockJobsAPI: JobsAPI {
    private var jobs: [String: Job]
    /// Seconds between automatic status changes after funding. 0 turns the simulation off.
    private let stepDelay: Double

    init(stepDelay: Double = 4) {
        self.stepDelay = stepDelay
        self.jobs = Dictionary(uniqueKeysWithValues: PosterFixtures.jobs.map { ($0.id, $0) })
    }

    // MARK: JobsAPI

    func presignUpload(contentType: String) async throws -> PresignedUpload {
        try await latency()
        let name = UUID().uuidString
        return PresignedUpload(
            uploadURL: URL(string: "https://mock-uploads.invalid/put/\(name)")!,
            fileURL: PosterFixtures.photo(name)
        )
    }

    func createJob(_ draft: NewJobDraft) async throws -> Job {
        try await latency(seconds: 1.5) // the real call waits on the LLM
        let job = Job(
            id: "job_\(UUID().uuidString.prefix(8))",
            title: draft.title,
            description: draft.description,
            category: draft.category,
            location: draft.location,
            deadline: draft.deadline,
            payAmount: draft.payAmount,
            currency: draft.currency,
            posterPhotos: draft.posterPhotos,
            checklist: PosterFixtures.checklist(for: draft),
            status: .draft
        )
        jobs[job.id] = job
        return job
    }

    func updateChecklist(jobId: String, checklist: [ChecklistItem]) async throws -> Job {
        try await latency()
        var job = try existing(jobId)
        guard job.status == .draft else { throw JobsAPIError.invalidState(job.status) }
        job.checklist = checklist
        jobs[jobId] = job
        return job
    }

    func startFunding(jobId: String) async throws -> FundingSession {
        try await latency()
        let job = try existing(jobId)
        guard job.status == .draft else { throw JobsAPIError.invalidState(job.status) }
        // Pretend the Stripe webhook arrives shortly after payment, then simulate the rest.
        Task { await self.simulateLifecycle(jobId: jobId) }
        return FundingSession(
            paymentIntentClientSecret: "pi_mock_secret",
            customerId: nil,
            ephemeralKeySecret: nil,
            publishableKey: "pk_test_mock"
        )
    }

    func job(id: String) async throws -> Job {
        try await latency(seconds: 0.2)
        return try existing(id)
    }

    func myJobs() async throws -> [Job] {
        try await latency()
        return jobs.values.sorted { $0.createdAt > $1.createdAt }
    }

    func approve(jobId: String) async throws -> Job {
        try await latency()
        var job = try existing(jobId)
        guard job.status == .inReview else { throw JobsAPIError.invalidState(job.status) }
        job.status = .released
        job.reviewDeadline = nil
        jobs[jobId] = job
        return job
    }

    func dispute(jobId: String, checklistItemId: String, note: String) async throws -> Job {
        try await latency()
        var job = try existing(jobId)
        guard job.status == .inReview else { throw JobsAPIError.invalidState(job.status) }
        job.status = .disputed
        job.reviewDeadline = nil
        jobs[jobId] = job
        return job
    }

    // MARK: Simulation

    private func simulateLifecycle(jobId: String) async {
        guard stepDelay > 0 else { return }
        let steps: [JobStatus] = [.funded, .offered, .accepted, .inProgress, .submitted, .inReview]
        for status in steps {
            try? await Task.sleep(for: .seconds(stepDelay))
            guard var job = jobs[jobId], !job.status.isTerminal, job.status != .disputed else { return }
            job.status = status
            switch status {
            case .accepted:
                job.worker = WorkerSummary(id: "w_mock", name: "Maya R.", rating: 4.8)
            case .submitted:
                job.proof = PosterFixtures.proof(for: job)
            case .inReview:
                job.verdicts = PosterFixtures.verdicts(for: job)
                job.reviewDeadline = .now.addingTimeInterval(120) // 2-minute demo window
            default:
                break
            }
            jobs[jobId] = job
        }
        // The window expires with no response, so the money releases automatically.
        try? await Task.sleep(for: .seconds(120))
        if var job = jobs[jobId], job.status == .inReview {
            job.status = .released
            job.reviewDeadline = nil
            jobs[jobId] = job
        }
    }

    // MARK: Helpers

    private func existing(_ id: String) throws -> Job {
        guard let job = jobs[id] else { throw JobsAPIError.notFound }
        return job
    }

    private func latency(seconds: Double = 0.4) async throws {
        try await Task.sleep(for: .seconds(seconds))
    }
}

// MARK: - Fixtures

/// Sample jobs from the poster's point of view, plus stand-ins for the AI.
enum PosterFixtures {
    static let annArbor = JobLocation(latitude: 42.2808, longitude: -83.7430, address: "State St, Ann Arbor, MI")

    static func photo(_ seed: String) -> URL {
        URL(string: "https://picsum.photos/seed/\(seed)/800/600")!
    }

    static var jobs: [Job] {
        let lawnChecklist = [
            ChecklistItem(id: "c_lawn_1", text: "Entire front lawn is mowed to an even height", evidenceType: .photo, photoCount: 4),
            ChecklistItem(id: "c_lawn_2", text: "Clippings are removed from the sidewalk and driveway", evidenceType: .photo, photoCount: 1),
            ChecklistItem(id: "c_lawn_3", text: "Worker checked in at the address", evidenceType: .checkIn),
        ]
        let logoChecklist = [
            ChecklistItem(id: "c_logo_1", text: "Sketch is on paper and shows a coffee-related symbol", evidenceType: .photo, photoCount: 1),
            ChecklistItem(id: "c_logo_2", text: "Shop name \"Bean There\" is legible in the sketch", evidenceType: .photo, photoCount: 1),
        ]

        var inReview = Job(
            id: "job_lawn",
            title: "Mow front lawn",
            description: "Small front yard, mower is in the garage. Please bag the clippings.",
            category: .yardWork,
            location: annArbor,
            deadline: .now.addingTimeInterval(6 * 3600),
            payAmount: 35,
            posterPhotos: [photo("lawn-before-1"), photo("lawn-before-2")],
            checklist: lawnChecklist,
            status: .inReview,
            worker: WorkerSummary(id: "w_1", name: "Jordan K.", rating: 4.9),
            reviewDeadline: .now.addingTimeInterval(120),
            createdAt: .now.addingTimeInterval(-3 * 3600)
        )
        inReview.proof = proof(for: inReview)
        inReview.verdicts = verdicts(for: inReview)

        return [
            inReview,
            Job(
                id: "job_logo",
                title: "Sketch a logo for a coffee shop",
                description: "Paper sketch of a logo for \"Bean There.\" Any style.",
                category: .design,
                deadline: .now.addingTimeInterval(2 * 3600),
                payAmount: 15,
                checklist: logoChecklist,
                status: .offered,
                createdAt: .now.addingTimeInterval(-600)
            ),
            Job(
                id: "job_move",
                title: "Help move a couch upstairs",
                description: "One couch, second floor, no elevator.",
                category: .moving,
                location: annArbor,
                deadline: .now.addingTimeInterval(24 * 3600),
                payAmount: 40,
                currency: .usdc,
                checklist: [ChecklistItem(id: "c_move_1", text: "Couch is in the second-floor living room", evidenceType: .photo, photoCount: 1)],
                status: .inProgress,
                worker: WorkerSummary(id: "w_2", name: "Sam T.", rating: nil),
                createdAt: .now.addingTimeInterval(-5 * 3600)
            ),
            Job(
                id: "job_tutor",
                title: "Calc II tutoring, 1 hour",
                description: "Series convergence tests before Friday's exam.",
                category: .tutoring,
                deadline: .now.addingTimeInterval(-24 * 3600),
                payAmount: 25,
                checklist: [ChecklistItem(id: "c_tutor_1", text: "Session notes or a recording link", evidenceType: .link)],
                status: .released,
                worker: WorkerSummary(id: "w_3", name: "Priya S.", rating: 5.0),
                createdAt: .now.addingTimeInterval(-48 * 3600)
            ),
        ]
    }

    /// A stand-in for the LLM checklist generator.
    static func checklist(for draft: NewJobDraft) -> [ChecklistItem] {
        let subject = draft.title.isEmpty ? "The task" : draft.title
        var items = [ChecklistItem(text: "\(subject) is fully completed as described", evidenceType: .photo, photoCount: 2)]
        if !draft.posterPhotos.isEmpty {
            items.append(ChecklistItem(text: "After photos match the angles of the poster's before photos", evidenceType: .photo, photoCount: draft.posterPhotos.count))
        }
        if draft.location != nil {
            items.append(ChecklistItem(text: "Worker checked in at the job location", evidenceType: .checkIn))
        } else {
            items.append(ChecklistItem(text: "A link or file showing the finished work", evidenceType: .link))
        }
        return items
    }

    static func proof(for job: Job) -> Proof {
        Proof(
            items: job.checklist.map { item in
                switch item.evidenceType {
                case .photo:
                    ProofItem(checklistItemId: item.id, photoURLs: (0..<(item.photoCount ?? 1)).map { photo("\(item.id)-after-\($0)") })
                case .checkIn:
                    ProofItem(checklistItemId: item.id, checkedInAt: .now.addingTimeInterval(-1800))
                case .link, .file:
                    ProofItem(checklistItemId: item.id, link: URL(string: "https://example.com/proof/\(item.id)"))
                }
            },
            submittedAt: .now
        )
    }

    static func verdicts(for job: Job) -> [Verdict] {
        job.checklist.enumerated().map { index, item in
            // The last item is a low-confidence pass so the review screen shows both looks.
            let isLast = index == job.checklist.count - 1 && job.checklist.count > 1
            return Verdict(
                checklistItemId: item.id,
                pass: true,
                confidence: isLast ? 0.62 : 0.94,
                explanation: isLast ? "Likely met, but one photo is partly blurred." : "Evidence clearly shows this item is done."
            )
        }
    }
}
