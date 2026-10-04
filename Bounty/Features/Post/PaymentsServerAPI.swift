// The standalone payments server (payments-server/): USDC escrow jobs and their status. Card checkout
// for marketplace jobs goes through the main backend instead (JobFundingSheet).
import SwiftUI

struct FundingDraft: Codable, Identifiable {
    let id: UUID
    let title: String
    let details: String
    let category: String
    let isRemote: Bool
    let deadline: String
    let amountCents: Int
    var location: JobLocation? = nil
}

struct FundedJob: Codable, Identifiable {
    let id: UUID
    let title: String
    let details: String
    let category: String
    let isRemote: Bool
    let deadline: String
    let amountCents: Int
    let feeCents: Int
    let totalCents: Int
    let currency: String
    let status: String
    let fundingRail: String?
    let posterWallet: String?
    let chainID: Int?
    let escrowAddress: String?
    let chainJobID: String?
    let settlementReference: String?
    var deadlineDate: Date? { Self.dateFormatter.date(from: deadline) ?? ISO8601DateFormatter().date(from: deadline) }

    var job: Job {
        Job(
            id: id.uuidString.lowercased(), title: title, pay: amountCents / 100,
            location: isRemote ? "Remote" : "In person",
            deadline: deadlineDate?.formatted(date: .abbreviated, time: .shortened) ?? deadline,
            sticker: PostDraft.sticker(for: category), tileColor: PostDraft.tileColor(for: category),
            status: JobStatus.api(status), currency: fundingRail == "usdc" ? "USDC" : "USD", payCents: amountCents
        )
    }

    private static var dateFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

private struct PaymentServerError: Decodable { let error: String }

@MainActor
struct PaymentAPI {
    var baseURLKey = "BountyPaymentsBaseURL"
    func status(for id: UUID) async throws -> FundedJob {
        try await request(path: "jobs/\(id.uuidString.lowercased())", method: "GET")
    }

    func request<Response: Decodable>(path: String, method: String, body: Data? = nil, token: String? = nil) async throws -> Response {
        guard let value = Bundle.main.object(forInfoDictionaryKey: baseURLKey) as? String,
              let baseURL = URL(string: value), let host = baseURL.host,
              ["http", "https"].contains(baseURL.scheme) else {
            throw PaymentAPIError(message: "Configure the Bounty payments server URL in Config/Local.xcconfig.")
        }
        #if !DEBUG
        guard baseURL.scheme == "https" else {
            throw PaymentAPIError(message: "The payments server must use HTTPS.")
        }
        #endif
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .notConnectedToInternet].contains(error.code) {
            throw PaymentAPIError(message: "Couldn’t connect to the payments server at \(host). Check that it’s running and try again.")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(PaymentServerError.self, from: data))?.error
            throw PaymentAPIError(message: message ?? "The payment service is unavailable. Please retry.", statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}

struct PaymentAPIError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

@MainActor
final class PostedJobsStore: ObservableObject {
    @Published private(set) var fundedJobs: [FundedJob]
    @Published var refreshError: String?
    private var pendingIDs: [UUID]
    private var usdcIDs: Set<UUID>
    private let defaults: UserDefaults
    private let api = PaymentAPI()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        usdcIDs = Set((defaults.stringArray(forKey: "usdcPaymentJobIDs") ?? []).compactMap(UUID.init(uuidString:)))
        fundedJobs = defaults.data(forKey: "fundedJobs")
            .flatMap { try? JSONDecoder().decode([FundedJob].self, from: $0) } ?? []
        pendingIDs = (defaults.stringArray(forKey: "pendingPaymentJobIDs") ?? []).compactMap(UUID.init(uuidString:))
    }

    func track(_ id: UUID, fundingRail: String = "stripe") {
        if fundingRail == "usdc" {
            usdcIDs.insert(id)
            defaults.set(usdcIDs.map(\.uuidString), forKey: "usdcPaymentJobIDs")
        }
        if !pendingIDs.contains(id) { pendingIDs.append(id) }
        defaults.set(pendingIDs.map(\.uuidString), forKey: "pendingPaymentJobIDs")
    }

    func record(_ job: FundedJob) {
        guard job.status != "draft" else { return }
        fundedJobs.removeAll { $0.id == job.id }
        fundedJobs.insert(job, at: 0)
        pendingIDs.removeAll { $0 == job.id }
        defaults.set(try? JSONEncoder().encode(fundedJobs), forKey: "fundedJobs")
        defaults.set(pendingIDs.map(\.uuidString), forKey: "pendingPaymentJobIDs")
    }

    func refresh() async {
        refreshError = nil
        // Recover a successful charge even if the app closed before confirmation returned.
        for id in Set(pendingIDs + fundedJobs.map(\.id)) {
            do {
                let isUSDC = usdcIDs.contains(id) || fundedJobs.contains { $0.id == id && $0.fundingRail == "usdc" }
                let service = isUSDC ? PaymentAPI(baseURLKey: "BountySettlementsBaseURL") : api
                record(try await service.status(for: id))
            }
            catch let error as PaymentAPIError where error.statusCode == 404 && pendingIDs.contains(id) {
                // A failed preparation never created this job; no payment could be launched.
                pendingIDs.removeAll { $0 == id }
                defaults.set(pendingIDs.map(\.uuidString), forKey: "pendingPaymentJobIDs")
            }
            catch { refreshError = error.localizedDescription }
        }
    }
}
