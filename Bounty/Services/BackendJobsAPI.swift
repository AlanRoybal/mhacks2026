import Foundation
import TwinKit

/// The poster's job routes on the main backend (`docs/API.md`, "Jobs › Poster").
///
/// Requests carry the signed-in user's session (TwinKit's `SessionStore`), so posting and working
/// happen under one account. Debug builds with no session fall back to the demo handle
/// `guest-poster`, which only a local backend accepts without a demo key.
actor BackendJobsAPI: JobsAPI {
    let baseURL: URL
    private let tokenProvider: (any AccessTokenProvider)?
    private var demoToken: String?

    init(baseURL: URL, tokenProvider: (any AccessTokenProvider)? = nil) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
    }

    /// True for errors that mean the backend isn't running or can't be reached.
    nonisolated static func isUnreachable(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        return [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .timedOut, .networkConnectionLost]
            .contains(urlError.code)
    }

    // MARK: JobsAPI

    func presignUpload(contentType: String) async throws -> PresignedUpload {
        try await send("POST", "uploads/presign", body: ["contentType": contentType])
    }

    func createJob(_ draft: NewJobDraft) async throws -> PostedJob {
        try await send("POST", "jobs", body: draft)
    }

    func updateDraft(jobId: String, _ draft: NewJobDraft) async throws -> PostedJob {
        try await send("PATCH", "jobs/\(jobId)", body: draft)
    }

    func deleteDraft(jobId: String) async throws {
        _ = try await data("DELETE", "jobs/\(jobId)", body: nil as Empty?)
    }

    func updateChecklist(jobId: String, checklist: [ChecklistItem]) async throws -> PostedJob {
        try await send("PUT", "jobs/\(jobId)/checklist", body: ["checklist": checklist])
    }

    func regenerateChecklist(jobId: String) async throws -> PostedJob {
        try await send("POST", "jobs/\(jobId)/checklist/regenerate")
    }

    func fund(jobId: String) async throws -> FundingResult {
        try await send("POST", "jobs/\(jobId)/fund")
    }

    func cancel(jobId: String) async throws -> PostedJob {
        try await send("POST", "jobs/\(jobId)/cancel")
    }

    func timeline(jobId: String) async throws -> [TimelineEntry] {
        try await send("GET", "jobs/\(jobId)/timeline")
    }

    func job(id: String) async throws -> PostedJob {
        try await send("GET", "jobs/\(id)")
    }

    func myJobs() async throws -> [PostedJob] {
        try await send("GET", "jobs/mine")
    }

    func approve(jobId: String) async throws -> PostedJob {
        try await send("POST", "jobs/\(jobId)/approve")
    }

    func dispute(jobId: String, checklistItemId: String, note: String) async throws -> PostedJob {
        try await send("POST", "jobs/\(jobId)/dispute", body: ["checklistItemId": checklistItemId, "note": note])
    }

    func rate(jobId: String, stars: Int, comment: String?) async throws -> PostedJob {
        try await send("POST", "jobs/\(jobId)/rating", body: RatingBody(stars: stars, comment: comment))
    }

    private struct RatingBody: Encodable {
        let stars: Int
        let comment: String?
    }

    func registerDevice(token: String) async throws {
        #if DEBUG
        let env = "sandbox"     // Xcode builds use APNs' sandbox
        #else
        let env = "production"  // TestFlight and App Store builds
        #endif
        let _: DeviceCount = try await send("POST", "me/devices", body: ["token": token, "env": env])
    }

    private struct DeviceCount: Decodable { let devices: Int }

    // MARK: Requests

    private func send<Response: Decodable>(_ method: String, _ path: String) async throws -> Response {
        try await send(method, path, body: nil as Empty?)
    }

    private func send<Response: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body?) async throws -> Response {
        try Self.decoder.decode(Response.self, from: try await data(method, path, body: body))
    }

    /// Sends the request and returns the body of a 2xx response.
    private func data<Body: Encodable>(_ method: String, _ path: String, body: Body?, isRetry: Bool = false) async throws -> Data {
        let token = try await currentToken()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 35 // creating a draft waits on the AI checklist
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }

        let (payload, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // A restarted local backend forgets demo sessions: sign in again once.
        if status == 401, !isRetry, demoToken != nil {
            demoToken = nil
            return try await data(method, path, body: body, isRetry: true)
        }
        if status == 401 {
            throw JobsAPIError.server("Your session expired. Sign in again.")
        }
        guard (200..<300).contains(status) else {
            throw JobsAPIError.server(Self.errorMessage(from: payload) ?? "The server returned an error (\(status)).")
        }
        return payload
    }

    private func currentToken() async throws -> String {
        if let token = await tokenProvider?.accessToken() { return token }
        #if DEBUG
        if let demoToken { return demoToken }
        #else
        throw JobsAPIError.server("Sign in to post and manage jobs.")
        #endif
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/demo"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["handle": "guest-poster", "displayName": "Guest poster"])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let session = try? JSONDecoder().decode(DemoSession.self, from: data) else {
            throw JobsAPIError.server(Self.errorMessage(from: data) ?? "Couldn't sign in to the Bounty backend.")
        }
        demoToken = session.token
        return session.token
    }

    private struct DemoSession: Decodable { let token: String }
    private struct Empty: Encodable {}

    /// Reads both error shapes: `{ "error": { "code", "message" } }` and the checkout's `{ "error": "..." }`.
    private static func errorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = object["error"] as? [String: Any] { return error["message"] as? String }
        return object["error"] as? String
    }

    // MARK: JSON

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Accepts ISO 8601 dates with or without fractional seconds.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: .iso8601) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unreadable date: \(text)"))
        }
        return decoder
    }()
}
