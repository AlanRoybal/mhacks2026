import Foundation

/// The poster's job routes on the main backend (`docs/API.md`, "Jobs › Poster").
///
/// In local dev it signs in as the demo handle `guest-poster`, the same account Caleb's checkout
/// files jobs under when it sends no session, so jobs funded through the checkout show up here.
/// Deployed stages need a real session: swap `signIn()` for TwinKit's `SessionStore` token.
actor BackendJobsAPI: JobsAPI {
    let baseURL: URL
    private var token: String?

    init(baseURL: URL) {
        self.baseURL = baseURL
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

    func updateChecklist(jobId: String, checklist: [ChecklistItem]) async throws -> PostedJob {
        try await send("PUT", "jobs/\(jobId)/checklist", body: ["checklist": checklist])
    }

    func startFunding(jobId: String) async throws -> FundingSession {
        try await send("POST", "jobs/\(jobId)/fund")
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

    private func send<Response: Decodable, Body: Encodable>(
        _ method: String,
        _ path: String,
        body: Body?,
        isRetry: Bool = false
    ) async throws -> Response {
        let token = try await currentToken()
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        // A restarted local backend forgets sessions: sign in again once.
        if status == 401, !isRetry {
            self.token = nil
            return try await send(method, path, body: body, isRetry: true)
        }
        guard (200..<300).contains(status) else {
            throw JobsAPIError.server(Self.errorMessage(from: data) ?? "The server returned an error (\(status)).")
        }
        return try Self.decoder.decode(Response.self, from: data)
    }

    private func currentToken() async throws -> String {
        if let token { return token }
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
        token = session.token
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
