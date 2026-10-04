import StripePaymentSheet
import SwiftUI

/// Card or Apple Pay checkout for a backend draft (US-15/16): `POST /jobs/{id}/fund`, then Stripe's
/// PaymentSheet. Stripe's webhook moves the job to FUNDED, so after paying this polls the job until it does.
/// With the backend's fake rail, the job is funded the moment `fund` returns.
struct JobFundingSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(PosterStore.self) private var posterStore
    let job: PostedJob
    let onFunded: (PostedJob) -> Void

    @State private var paymentSheet: PaymentSheet?
    @State private var funded: PostedJob?
    @State private var isBusy = false
    @State private var didPay = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            List {
                if let funded {
                    Section {
                        Label("Funded", icon: .checkCircle)
                            .foregroundStyle(BountyColor.greenInk)
                            .font(.title2.bold())
                        Text("Your twin is looking for a worker now. Follow along in Jobs \u{2192} Posted.")
                        Button("Done") {
                            onFunded(funded)
                            dismiss()
                        }
                        .font(.headline)
                    }
                } else {
                    Section("Job") {
                        Text(job.title).font(.headline)
                        Text("\(job.checklist.count) proof items · due \(job.deadlineText)").foregroundStyle(.secondary)
                    }
                    Section("Payment summary") {
                        row("Job pay", job.payAmount)
                        row("Platform fee", job.feeAmount ?? job.payAmount / 10)
                        row("Total", job.totalAmount ?? job.payAmount * 11 / 10).font(.headline)
                    }
                    Section {
                        if isBusy {
                            HStack { ProgressView(); Text(didPay ? "Confirming payment\u{2026}" : "Preparing checkout\u{2026}") }
                        } else if didPay {
                            Button("Check payment status") { Task { await confirm() } }
                        } else if let paymentSheet {
                            PaymentSheet.PaymentButton(paymentSheet: paymentSheet, onCompletion: handle) {
                                Text("Pay \((job.totalAmount ?? job.payAmount * 11 / 10).formatted(.currency(code: "USD"))) & fund job")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                        } else {
                            Button("Retry checkout") { Task { await prepare() } }
                        }
                    } footer: {
                        Text("Held until the work is approved. Full refund if nobody finishes by the deadline. Stripe test mode: no real money is charged.")
                    }
                    if let message {
                        Section { Text(message).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Fund job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(isBusy || (didPay && funded == nil))
                }
            }
            .interactiveDismissDisabled(isBusy || (didPay && funded == nil))
            .task { await prepare() }
        }
    }

    private func row(_ label: String, _ amount: Decimal) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(amount, format: .currency(code: "USD"))
        }
    }

    private func prepare() async {
        guard !isBusy else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        do {
            let result = try await posterStore.api.fund(jobId: job.id)
            guard result.needsPaymentSheet, let secret = result.paymentIntentClientSecret, let key = result.publishableKey else {
                funded = result.job
                posterStore.upsert(result.job)
                return
            }
            guard key.hasPrefix("pk_test_") else { throw JobsAPIError.server("This build requires Stripe test mode.") }
            STPAPIClient.shared.publishableKey = key
            var configuration = PaymentSheet.Configuration()
            configuration.merchantDisplayName = "Bounty"
            configuration.returnURL = "bounty://stripe-redirect"
            configuration.allowsDelayedPaymentMethods = false
            if let merchantID = Bundle.main.object(forInfoDictionaryKey: "BountyApplePayMerchantIdentifier") as? String,
               merchantID.hasPrefix("merchant.") {
                configuration.applePay = .init(merchantId: merchantID, merchantCountryCode: "US")
            }
            paymentSheet = PaymentSheet(paymentIntentClientSecret: secret, configuration: configuration)
        } catch {
            message = error.localizedDescription
        }
    }

    private func handle(_ result: PaymentSheetResult) {
        switch result {
        case .completed:
            didPay = true
            paymentSheet = nil
            Task { await confirm() }
        case .canceled:
            message = "Payment canceled. You can try again when you\u{2019}re ready."
        case .failed(let error):
            message = error.localizedDescription
        }
    }

    /// Waits up to ~30 s for the webhook to mark the job funded.
    private func confirm() async {
        isBusy = true
        message = nil
        defer { isBusy = false }
        for _ in 0..<15 {
            if let fresh = await posterStore.refresh(jobId: job.id), fresh.status != .draft {
                funded = fresh
                return
            }
            try? await Task.sleep(for: .seconds(2))
        }
        message = "Your payment went through and is still being confirmed. It will show in Jobs \u{2192} Posted shortly."
    }
}
