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
