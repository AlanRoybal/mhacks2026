import SwiftUI
import Security

struct WorkerProfile: Codable {
    let id: String
    let connectAccountID: String?
    let walletAddress: String?
}
private struct WorkerSession: Codable { let worker: WorkerProfile; let token: String }
struct EarningsTotal: Decodable { let pendingCents: Int; let releasedCents: Int }
struct EarningsTotals: Decodable { let usd: EarningsTotal; let usdc: EarningsTotal }
struct EarningsEntry: Decodable, Identifiable {
    let jobID: String
    let title: String
    let amountCents: Int
    let rail: String
    let status: String
    let reference: String?
    let issue: String?
    var id: String { jobID }
}
struct EarningsResponse: Decodable { let totals: EarningsTotals; let entries: [EarningsEntry] }
private struct OnboardingLink: Decodable { let url: String }
private struct WalletChallenge: Decodable { let message: String }

@MainActor
final class WorkerPayments: ObservableObject {
    @Published private(set) var profile: WorkerProfile?
    @Published private(set) var earnings: EarningsResponse?
    @Published private(set) var assignedJobs: [FundedJob] = []
    var jobs: [Job] {
        assignedJobs.map { record in
            var job = record.job
            if earnings?.entries.first(where: { $0.jobID == record.id.uuidString.lowercased() })?.status == "settlement_issue" {
                job.status = .settlementIssue
            }
            return job
        }
    }
    @Published private(set) var busy = false
    @Published var message: String?
    private var session: WorkerSession?
    private let api = PaymentAPI(baseURLKey: "BountySettlementsBaseURL")
    private let service = "com.alanroybal.BountyTwin.worker-session"

    init() {
        var value: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: "worker", kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        if SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data {
            session = try? JSONDecoder().decode(WorkerSession.self, from: data)
            profile = session?.worker
        }
    }
    private func ensureSession() async throws -> WorkerSession {
        if let session { return session }
        let created: WorkerSession = try await api.request(path: "workers/session", method: "POST")
        let data = try JSONEncoder().encode(created)
        let key: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "worker"]
        SecItemDelete(key as CFDictionary)
        var attributes = key
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else { throw PaymentAPIError(message: "Couldn’t save your payment profile securely.") }
        session = created; profile = created.worker
        return created
    }
    func refresh() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let session = try await ensureSession()
            profile = try await api.request(path: "workers/me", method: "GET", token: session.token)
            earnings = try await api.request(path: "workers/me/earnings", method: "GET", token: session.token)
            assignedJobs = try await api.request(path: "workers/me/jobs", method: "GET", token: session.token)
        } catch { message = error.localizedDescription }
    }
    func onboardingURL() async -> URL? {
        guard !busy else { return nil }
        busy = true; message = nil
        defer { busy = false }
        do {
            let session = try await ensureSession()
            let link: OnboardingLink = try await api.request(path: "workers/me/connect", method: "POST", token: session.token)
            guard let url = URL(string: link.url), url.scheme == "https" else { throw PaymentAPIError(message: "Invalid payout setup link.") }
            return url
        } catch { message = error.localizedDescription; return nil }
    }
    func connectWallet() async {
        guard !busy else { return }
        busy = true; message = nil
        defer { busy = false }
        do {
            let session = try await ensureSession()
            let wallet = BountyWallet.shared
            try await wallet.connect()
            guard let address = wallet.address else { return }
            let challenge: WalletChallenge = try await api.request(path: "workers/me/wallet/challenge", method: "POST",
                body: JSONEncoder().encode(["address": address]), token: session.token)
            let signature = try await wallet.sign(challenge.message)
            profile = try await api.request(path: "workers/me/wallet/verify", method: "POST",
                body: JSONEncoder().encode(["signature": signature]), token: session.token)
        } catch { message = error.localizedDescription }
    }
}
