@preconcurrency import CoinbaseWalletSDK
import SwiftUI

@MainActor
final class BountyWallet: ObservableObject {
    static let shared = BountyWallet()
    @Published private(set) var address: String? = UserDefaults.standard.string(forKey: "posterWalletAddress")

    static func configure() {
        if !CoinbaseWalletSDK.isConfigured {
            // Not bounty://wallet: that's Stripe Connect's return link (EarningsView).
            CoinbaseWalletSDK.configure(callback: URL(string: "bounty://cbwallet")!)
        }
    }
    func connect() async throws {
        Self.configure()
        guard CoinbaseWalletSDK.isCoinbaseWalletInstalled() else {
            throw PaymentAPIError(message: "Install Coinbase Wallet on your iPhone to connect a test wallet.")
        }
        let connected: String = try await withCheckedThrowingContinuation { continuation in
            CoinbaseWalletSDK.shared.initiateHandshake { result, account in
                switch result {
                case .failure(let error): continuation.resume(throwing: error)
                case .success:
                    guard let account else { continuation.resume(throwing: PaymentAPIError(message: "Wallet connection was declined.")); return }
                    continuation.resume(returning: account.address)
                }
            }
        }
        address = connected
        UserDefaults.standard.set(connected, forKey: "posterWalletAddress")
    }
    func request(_ action: Web3JSONRPC) async throws -> String {
        Self.configure()
        guard let address, CoinbaseWalletSDK.shared.isConnected() else { throw PaymentAPIError(message: "Connect your wallet first.") }
        return try await withCheckedThrowingContinuation { continuation in
            CoinbaseWalletSDK.shared.makeRequest(Request(actions: [Action(jsonRpc: action)],
                account: Account(chain: "eth", networkId: 84532, address: address))) { result in
                do {
                    guard let actionResult = try result.get().content.first else { throw PaymentAPIError(message: "The wallet returned no result.") }
                    let value = try actionResult.get()
                    continuation.resume(returning: (try value.decode(as: String.self)) ?? "")
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func send(to: String, data: String) async throws -> String {
        guard let address else { throw PaymentAPIError(message: "Connect your wallet first.") }
        let hash = try await request(.eth_sendTransaction(fromAddress: address, toAddress: to, weiValue: "0", data: data,
            nonce: nil, gasPriceInWei: nil, maxFeePerGas: nil, maxPriorityFeePerGas: nil, gasLimit: nil, chainId: "84532", actionSource: nil))
        guard hash.hasPrefix("0x"), hash.count == 66 else { throw PaymentAPIError(message: "The wallet did not return a transaction hash.") }
        return hash
    }
    func sign(_ message: String) async throws -> String {
        guard let address else { throw PaymentAPIError(message: "Connect your wallet first.") }
        return try await request(.personal_sign(address: address, message: message))
    }
}

struct CryptoTransaction: Decodable { let to: String; let data: String }
struct CryptoPreparation: Decodable {
    let job: FundedJob
    let chainID: Int
    let tokenAddress: String
    let escrowAddress: String
    let amountUnits: String
    let approve: CryptoTransaction
    let deposit: CryptoTransaction
    let refund: CryptoTransaction
}
private struct ReceiptState: Decodable { let status: String }

@MainActor
struct CryptoCheckoutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var postedJobs: PostedJobsStore
    @ObservedObject private var wallet = BountyWallet.shared
    @State private var prepared: CryptoPreparation?
    @State private var confirmedJob: FundedJob?
    @State private var funded = false
    @State private var busy = false
    @State private var message: String?
    @State private var stage = ""
    let draft: FundingDraft
    let onFunded: () -> Void
    private let api = PaymentAPI(baseURLKey: "BountySettlementsBaseURL")

    var body: some View {
        NavigationStack {
            List {
                Section("Job") { Text(draft.title).font(.headline); Text(draft.details) }
                Section("Payment") {
                    LabeledContent("Job pay", value: "\((Decimal(draft.amountCents) / 100).formatted()) USDC")
                    Text("Base Sepolia testnet. Your wallet authorizes each transaction and pays gas in test ETH.").font(.footnote)
                    if let address = wallet.address { Text(address).font(.caption.monospaced()).textSelection(.enabled) }
                }
                Section {
                    if funded {
                        Label(JobStatus.api(confirmedJob?.status ?? "funded").rawValue, icon: .checkCircle).foregroundStyle(BountyColor.greenInk)
                        Button("Done") { onFunded(); dismiss() }
                    } else if busy {
                        HStack { ProgressView(); Text(stage) }
                    } else {
                        Button("Connect Coinbase Wallet") { Task { await perform("Connecting wallet…") { try await wallet.connect() } } }
                        if wallet.address != nil {
                            Button("Approve USDC & fund job") { Task { await fund() } }
                            Button("Check funding status") { Task { await refresh() } }
                        }
                    }
                    if let message { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Fund with USDC")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
            .interactiveDismissDisabled(busy)
        }
    }
    private func perform(_ stage: String, action: () async throws -> Void) async {
        guard !busy else { return }
        busy = true; self.stage = stage; message = nil
        defer { busy = false }
        do { try await action() } catch { message = error.localizedDescription }
    }
    private func fund() async {
        await perform("Preparing escrow…") {
            guard let address = wallet.address else { return }
            var body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(draft)) as! [String: Any]
            body["posterWallet"] = address
            postedJobs.track(draft.id, fundingRail: "usdc")
            let preparation: CryptoPreparation = try await api.request(path: "crypto/prepare", method: "POST", body: JSONSerialization.data(withJSONObject: body))
            prepared = preparation
            guard preparation.chainID == 84532 else { throw PaymentAPIError(message: "This checkout requires Base Sepolia.") }
            if preparation.job.status != "draft" { postedJobs.record(preparation.job); confirmedJob = preparation.job; funded = true; return }
            stage = "Approve the USDC amount in your wallet…"
            let approval = try await wallet.send(to: preparation.approve.to, data: preparation.approve.data)
            stage = "Waiting for approval confirmation…"
            let receipt: ReceiptState = try await api.request(path: "crypto/receipts/\(approval)", method: "GET")
            guard receipt.status == "success" else { throw PaymentAPIError(message: "USDC approval reverted. Your job remains unfunded.") }
            stage = "Confirm the deposit in your wallet…"
            let deposit = try await wallet.send(to: preparation.deposit.to, data: preparation.deposit.data)
            // Recovery uses the known job ID even if the app closes after the wallet sends.
            stage = "Confirming escrow funding…"
            let job: FundedJob = try await api.request(path: "crypto/jobs/\(draft.id.uuidString.lowercased())/confirm", method: "POST",
                body: JSONEncoder().encode(["transactionHash": deposit]))
            postedJobs.record(job); confirmedJob = job; funded = job.status != "draft"
            if !funded { message = "The deposit is still being confirmed. Check its status again." }
        }
    }
    private func refresh() async {
        await perform("Checking escrow…") {
            let job = try await api.status(for: draft.id)
            postedJobs.record(job); confirmedJob = job; funded = job.status != "draft"
            if !funded { message = "This job is not funded yet." }
        }
    }
}
