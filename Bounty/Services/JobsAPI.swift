import Foundation

/// Everything the poster app needs from the backend. Screens talk only to this protocol,
/// so swapping `MockJobsAPI` for the real client is a one-line change at app launch.
protocol JobsAPI: Sendable {
    /// `uploads/presign`: returns where to PUT the bytes and the file's stable URL.
    func presignUpload(contentType: String) async throws -> PresignedUpload

    /// `POST jobs`: creates a DRAFT job and returns it with the AI-generated checklist (US-11/13).
    func createJob(_ draft: NewJobDraft) async throws -> PostedJob

    /// `PATCH jobs/{id}`: changes a draft's details after the poster goes back and edits them.
    func updateDraft(jobId: String, _ draft: NewJobDraft) async throws -> PostedJob

    /// `DELETE jobs/{id}`: drafts only.
    func deleteDraft(jobId: String) async throws

    /// `jobs/{id}/checklist`: saves the poster's edits to the checklist (US-14).
    func updateChecklist(jobId: String, checklist: [ChecklistItem]) async throws -> PostedJob

    /// `jobs/{id}/checklist/regenerate`: asks the AI for a fresh checklist.
    func regenerateChecklist(jobId: String) async throws -> PostedJob

    /// `jobs/{id}/fund`: a Stripe PaymentSheet session, or an already funded job with the fake rail (US-16).
    func fund(jobId: String) async throws -> FundingResult

    /// `jobs/{id}/cancel`: before a worker accepts. Full refund (US-18).
    func cancel(jobId: String) async throws -> PostedJob

    /// `jobs/{id}/timeline`: every status change, oldest first (US-17/49).
    func timeline(jobId: String) async throws -> [TimelineEntry]

    /// `jobs/{id}`: current state, worker, proof and verdicts.
    func job(id: String) async throws -> PostedJob

    /// `jobs/mine`: the signed-in poster's jobs, newest first.
    func myJobs() async throws -> [PostedJob]

    /// `jobs/{id}/approve`: asks the server to release payment. The server decides; the app never moves money.
    func approve(jobId: String) async throws -> PostedJob

    /// `jobs/{id}/dispute` (stretch).
    func dispute(jobId: String, checklistItemId: String, note: String) async throws -> PostedJob

    /// `jobs/{id}/rating`: rates the other side 1–5 once the job is paid or refunded (US-56/57).
    func rate(jobId: String, stars: Int, comment: String?) async throws -> PostedJob

    /// `me/devices`: lets the server push to this device. `token` is the APNs token in hex.
    func registerDevice(token: String) async throws
}

extension JobsAPI {
    /// Sample data has no server to push from.
    func registerDevice(token: String) async throws {}

    /// Presigns, then PUTs the bytes. Returns the file URL to send in other requests.
    func upload(_ data: Data, contentType: String) async throws -> URL {
        let target = try await presignUpload(contentType: contentType)
        try await target.put(data, contentType: contentType)
        return target.fileURL
    }
}

/// `POST /uploads/presign`. PUT the bytes to `uploadURL` with exactly `headers`, then refer to the file by `fileURL`.
struct PresignedUpload: Codable, Hashable, Sendable {
    let uploadURL: URL
    let fileURL: URL
    var method: String?
    var headers: [String: String]?

    init(uploadURL: URL, fileURL: URL, method: String? = "PUT", headers: [String: String]? = nil) {
        self.uploadURL = uploadURL
        self.fileURL = fileURL
        self.method = method
        self.headers = headers
    }

    func put(_ data: Data, contentType: String) async throws {
        // Sample data uploads go nowhere.
        guard uploadURL.host() != "mock-uploads.invalid" else { return }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = method ?? "PUT"
        request.timeoutInterval = 60
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        let (_, response) = try await URLSession.shared.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JobsAPIError.server("The upload didn\u{2019}t go through. Check your connection and try again.")
        }
    }
}

/// `POST /jobs/{id}/fund`. With Stripe, present PaymentSheet; with the fake rail, `job` is already FUNDED.
struct FundingResult: Codable, Hashable, Sendable {
    let provider: String
    let paymentIntentClientSecret: String?
    let publishableKey: String?
    let job: PostedJob

    var needsPaymentSheet: Bool { provider == "stripe" && paymentIntentClientSecret != nil }
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
