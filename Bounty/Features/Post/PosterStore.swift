import Foundation
import Observation

/// The poster side's shared state. Views read from it; only it talks to `JobsAPI`.
@MainActor
@Observable
final class PosterStore {
    private(set) var jobs: [Job] = []
    private(set) var isLoading = false
    var errorMessage: String?

    let api: any JobsAPI
    /// The Post tab's form. Lives here so it survives moving between the posting screens.
    let form = CreateJobModel()

    init(api: any JobsAPI) {
        self.api = api
    }

    func loadJobs() async {
        isLoading = true
        defer { isLoading = false }
        do {
            jobs = try await api.myJobs()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches one job and replaces it in the list. Returns the fresh copy.
    @discardableResult
    func refresh(jobId: String) async -> Job? {
        do {
            let job = try await api.job(id: jobId)
            upsert(job)
            return job
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func job(_ id: String?) -> Job? {
        guard let id else { return nil }
        return jobs.first { $0.id == id }
    }

    func upsert(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    // MARK: Posting

    /// Sends the form to `jobs/create` and returns the DRAFT job with its AI-generated checklist.
    func createJob(_ draft: NewJobDraft) async throws -> Job {
        let job = try await api.createJob(draft)
        upsert(job)
        return job
    }

    /// Saves the poster's checklist edits. Only allowed while the job is a draft.
    func updateChecklist(jobId: String, checklist: [ChecklistItem]) async throws -> Job {
        let job = try await api.updateChecklist(jobId: jobId, checklist: checklist)
        upsert(job)
        return job
    }

    /// Funds a draft job: asks the backend for a payment session, collects payment, then
    /// waits for the server to mark the job FUNDED (the Stripe webhook does that, not the app).
    func fund(_ job: Job) async throws -> Job {
        let session = try await api.startFunding(jobId: job.id)
        let paid = try await PaymentHandoff.collectPayment(session: session, job: job)
        guard paid else { throw FundingError.cancelled }

        // Poll briefly so the screen can say "Funded" once the webhook lands.
        for _ in 0..<15 {
            if let fresh = await refresh(jobId: job.id), fresh.status != .draft {
                return fresh
            }
            try await Task.sleep(for: .seconds(1))
        }
        // Payment went through; the webhook is just slow. The Posted list will catch up.
        return await refresh(jobId: job.id) ?? job
    }

    /// Approves submitted work. The server releases the payment; the app never moves money.
    func approve(_ job: Job) async throws {
        upsert(try await api.approve(jobId: job.id))
    }

    /// Disputes submitted work. The poster must name the requirement that wasn't met.
    func dispute(_ job: Job, item: ChecklistItem, note: String) async throws {
        upsert(try await api.dispute(jobId: job.id, checklistItemId: item.id, note: note))
    }

    enum FundingError: LocalizedError {
        case cancelled

        var errorDescription: String? { "Payment was cancelled." }
    }

    /// Uploads one JPEG through a presigned S3 URL and returns the photo's permanent URL.
    func uploadPhoto(jpegData: Data) async throws -> URL {
        let upload = try await api.presignUpload(contentType: "image/jpeg")
        // The mock hands out an unreachable upload URL; skip the PUT so it works offline.
        guard upload.uploadURL.host() != "mock-uploads.invalid" else { return upload.fileURL }

        var request = URLRequest(url: upload.uploadURL)
        request.httpMethod = "PUT"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: request, from: jpegData)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JobsAPIError.server("The photo didn't upload. Try again.")
        }
        return upload.fileURL
    }

    /// Jobs where the poster needs to act come first, then everything else by date.
    var sortedJobs: [Job] {
        jobs.sorted { lhs, rhs in
            if lhs.status.needsPosterAction != rhs.status.needsPosterAction {
                return lhs.status.needsPosterAction
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
}

/// Where Payments plugs in Stripe. Replace the body of `collectPayment` with the PaymentSheet
/// flow (configure with `session.publishableKey`, present with
/// `session.paymentIntentClientSecret`, return true on `.completed`). Everything else in the
/// poster flow already calls through here.
enum PaymentHandoff {
    @MainActor
    static func collectPayment(session: FundingSession, job: Job) async throws -> Bool {
        // Mock: pretend the sheet was shown and the poster paid.
        try await Task.sleep(for: .seconds(1))
        return true
    }
}
