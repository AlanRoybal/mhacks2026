import StripePaymentSheet
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

private struct PaymentSheetResponse: Decodable {
    let job: FundedJob
    let paymentIntentClientSecret: String
    let publishableKey: String
}

private struct PaymentServerError: Decodable { let error: String }

@MainActor
struct PaymentAPI {
    var baseURLKey = "BountyPaymentsBaseURL"
    func prepare(_ draft: FundingDraft) async throws -> (FundedJob, PaymentSheet) {
        let response: PaymentSheetResponse = try await request(
            path: "payment-sheet", method: "POST", body: JSONEncoder().encode(draft)
        )
        guard response.publishableKey.hasPrefix("pk_test_") else {
            throw PaymentAPIError(message: "This build requires Stripe test mode.")
        }
        STPAPIClient.shared.publishableKey = response.publishableKey
        var configuration = PaymentSheet.Configuration()
        configuration.merchantDisplayName = "Bounty"
        configuration.returnURL = "bounty://stripe-redirect"
        configuration.allowsDelayedPaymentMethods = false
        if let merchantID = Bundle.main.object(forInfoDictionaryKey: "BountyApplePayMerchantIdentifier") as? String,
           merchantID.hasPrefix("merchant.") {
            configuration.applePay = .init(merchantId: merchantID, merchantCountryCode: "US")
        }
        return (response.job, PaymentSheet(
            paymentIntentClientSecret: response.paymentIntentClientSecret, configuration: configuration
        ))
    }

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

@MainActor
private final class PaymentCheckoutModel: ObservableObject {
    @Published var paymentSheet: PaymentSheet?
    @Published var job: FundedJob?
    @Published var isBusy = false
    @Published var didCompletePayment = false
    @Published var message: String?
    let draft: FundingDraft
    private let api = PaymentAPI()
    var isFunded: Bool { job.map { $0.status != "draft" } ?? false }

    init(draft: FundingDraft) { self.draft = draft }

    func prepare(store: PostedJobsStore) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        store.track(draft.id)
        do {
            (job, paymentSheet) = try await api.prepare(draft)
            if let job, job.status != "draft" {
                store.record(job)
                paymentSheet = nil
            }
        } catch { message = error.localizedDescription }
    }

    func handle(_ result: PaymentSheetResult, store: PostedJobsStore) {
        switch result {
        case .completed:
            didCompletePayment = true
            paymentSheet = nil
            Task { await verify(store: store) }
        case .canceled:
            message = "Payment canceled. You can try again when you’re ready."
        case .failed(let error):
            message = error.localizedDescription
        }
    }

    func verify(store: PostedJobsStore) async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            for attempt in 0..<3 {
                let confirmed = try await api.status(for: draft.id)
                if confirmed.status != "draft" {
                    job = confirmed
                    store.record(confirmed)
                    return
                }
                if attempt < 2 { try await Task.sleep(for: .seconds(1)) }
            }
            message = "Your payment is still being confirmed. Check its status again in a moment."
        } catch { message = "Couldn’t confirm payment yet. Check its status again before starting another checkout. \(error.localizedDescription)" }
    }
}

struct PaymentCheckoutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var postedJobs: PostedJobsStore
    @StateObject private var model: PaymentCheckoutModel
    let onFunded: () -> Void

    init(draft: FundingDraft, onFunded: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PaymentCheckoutModel(draft: draft))
        self.onFunded = onFunded
    }

    var body: some View {
        NavigationStack {
            List {
                if model.isFunded {
                    Section {
                        Label(JobStatus.api(model.job?.status ?? "funded").rawValue, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(BountyColor.greenInk)
                            .font(.title2.bold())
                        Text("Your job is now in Jobs → Posted.")
                        Button("Done") { onFunded(); dismiss() }
                            .font(.headline)
                    }
                } else {
                    Section("Job") {
                        Text(model.draft.title).font(.headline)
                        Text(model.draft.details).foregroundStyle(.secondary)
                    }
                    Section("Payment summary") {
                        priceRow("Job pay", cents: model.job?.amountCents ?? model.draft.amountCents)
                        priceRow("Platform fee (10%)", cents: model.job?.feeCents ?? Int((Double(model.draft.amountCents) * 0.10).rounded()))
                        if let job = model.job { priceRow("Total", cents: job.totalCents).font(.headline) }
                    }
                    Section {
                        if model.isBusy {
                            HStack { ProgressView(); Text(model.didCompletePayment ? "Confirming payment…" : "Preparing checkout…") }
                        } else if model.didCompletePayment {
                            Button("Check payment status") { Task { await model.verify(store: postedJobs) } }
                        } else if let sheet = model.paymentSheet, let job = model.job {
                            PaymentSheet.PaymentButton(paymentSheet: sheet, onCompletion: { model.handle($0, store: postedJobs) }) {
                                Text("Pay \((Decimal(job.totalCents) / 100).formatted(.currency(code: "USD"))) & fund job")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                        } else {
                            Button("Retry checkout") { Task { await model.prepare(store: postedJobs) } }
                        }
                    } footer: {
                        Text("Stripe test mode. No real money is charged.")
                    }
                    if let message = model.message {
                        Section { Text(message).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Fund job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(model.isBusy || (model.didCompletePayment && !model.isFunded))
                }
            }
            .interactiveDismissDisabled(model.isBusy || (model.didCompletePayment && !model.isFunded))
            .task { await model.prepare(store: postedJobs) }
        }
    }

    private func priceRow(_ label: String, cents: Int) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(Decimal(cents) / 100, format: .currency(code: "USD"))
        }
    }
}
