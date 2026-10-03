import Foundation

/// Everything the poster app needs from the backend. Screens talk only to this protocol,
/// so swapping `MockJobsAPI` for the real client is a one-line change at app launch.
protocol JobsAPI: Sendable {
    /// `uploads/presign`: returns where to PUT the photo and its final URL.
    func presignUpload(contentType: String) async throws -> PresignedUpload

    /// `jobs/create`: creates a DRAFT job and returns it with the AI-generated checklist.
    func createJob(_ draft: NewJobDraft) async throws -> PostedJob

    /// `jobs/{id}/checklist`: saves the poster's edits to the checklist.
    func updateChecklist(jobId: String, checklist: [ChecklistItem]) async throws -> PostedJob

    /// `jobs/fund` (owned by Payments): returns the Stripe PaymentSheet client secret.
    func startFunding(jobId: String) async throws -> FundingSession

    /// `jobs/{id}`: current state, worker, proof and verdicts.
    func job(id: String) async throws -> PostedJob

    /// `jobs/mine`: the signed-in poster's jobs, newest first.
    func myJobs() async throws -> [PostedJob]

    /// `jobs/{id}/approve`: asks the server to release payment. The server decides; the app never moves money.
    func approve(jobId: String) async throws -> PostedJob

    /// `jobs/{id}/dispute` (stretch).
    func dispute(jobId: String, checklistItemId: String, note: String) async throws -> PostedJob
}

struct PresignedUpload: Codable, Hashable, Sendable {
    let uploadURL: URL
    let fileURL: URL

    init(uploadURL: URL, fileURL: URL) {
        self.uploadURL = uploadURL
        self.fileURL = fileURL
    }
}

struct FundingSession: Codable, Hashable, Sendable {
    let paymentIntentClientSecret: String
    let customerId: String?
    let ephemeralKeySecret: String?
    let publishableKey: String

    init(paymentIntentClientSecret: String, customerId: String?, ephemeralKeySecret: String?, publishableKey: String) {
        self.paymentIntentClientSecret = paymentIntentClientSecret
        self.customerId = customerId
        self.ephemeralKeySecret = ephemeralKeySecret
        self.publishableKey = publishableKey
    }
}

enum JobsAPIError: Error, LocalizedError, Sendable {
    case notFound
    case invalidState(PostedJobStatus)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "That job couldn't be found."
        case .invalidState(let status): "This can't be done while the job is \(status.displayName.lowercased())."
        case .server(let message): message
        }
    }
}
