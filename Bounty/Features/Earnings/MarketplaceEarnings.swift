import Foundation
import Observation
import TwinKit

/// The worker's marketplace earnings and Stripe payout setup on the main backend (US-52/53/54/55).
///
/// Jobs matched by the backend pay out through its Stripe Connect account for the worker, and with
/// Stripe on, the backend only matches workers whose payouts are enabled. So payout setup has to happen
/// here, not on the standalone payments server (which still handles USDC wallets; see `WorkerPayments`).
@MainActor
@Observable
final class MarketplaceEarnings {
    private(set) var summary: EarningsSummary?
    private(set) var isLoading = false
    var message: String?

    func refresh(api: APIClient?) async {
        guard let api, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            summary = try await api.request(.get, "wallet/earnings")
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// Stripe Express onboarding, opened in `SFSafariViewController`. It returns to `bounty://wallet`.
    func onboardingURL(api: APIClient?) async -> URL? {
        guard let api else { return nil }
        do {
            let link: ConnectLink = try await api.request(.post, "wallet/connect")
            guard let url = URL(string: link.url), url.scheme == "https" else { throw JobsAPIError.server("Invalid payout setup link.") }
            return url
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    /// Sets the share of each payout the tax jar tracks (0-50%).
    func setTaxSetAside(_ percent: Int, api: APIClient?) async {
        guard let api else { return }
        do {
            summary = try await api.request(.put, "wallet/tax", body: ["percent": percent])
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// After the worker comes back from Stripe: asks the backend to re-read the account's status.
    func syncPayouts(api: APIClient?) async {
        guard let api else { return }
        try? await api.send(.post, "wallet/connect/sync")
        await refresh(api: api)
    }

    private struct ConnectLink: Decodable, Sendable { let url: String }
}

/// `GET /wallet/earnings`.
struct EarningsSummary: Decodable, Sendable {
    /// Paid out in USD.
    let available: Decimal
    /// USD held for active jobs or on its way.
    let pending: Decimal
    let currencies: [CurrencyTotals]
    let payouts: PayoutStatus
    let items: [EarningItem]
    /// USD paid out this calendar year.
    let yearToDatePaid: Decimal?
    /// Average seconds from approval to the payout landing.
    let averageTimeToPaidSeconds: Int?
    /// The tracked tax set-aside (nothing is withheld).
    let taxSetAside: TaxSetAside?

    struct TaxSetAside: Decodable, Sendable {
        let percent: Int
        let amount: Decimal
    }

    struct CurrencyTotals: Decodable, Sendable {
        let currency: String
        let pending: Decimal
        let releasing: Decimal
        let paid: Decimal
    }

    struct PayoutStatus: Decodable, Sendable {
        let stripeConnected: Bool
        let payoutsEnabled: Bool
    }

    func totals(for currency: String) -> CurrencyTotals? { currencies.first { $0.currency == currency } }
}

/// One earning: a job's pay and where it is (US-55).
struct EarningItem: Decodable, Identifiable, Hashable, Sendable {
    let jobId: String
    let title: String
    let amount: Decimal
    let currency: String
    /// `pending`, `releasing`, `paid` or `refunded`.
    let status: String
    let jobStatus: String
    /// `stripe`, `usdc` or `fake`.
    let rail: String
    /// The Stripe transfer ID (or chain reference) once paid.
    let reference: String?
    let referenceUrl: String?
    let paidAt: Date?
    /// Seconds from approval to the payout landing.
    let timeToPaidSeconds: Int?
    let updatedAt: Date

    var id: String { jobId }

    var statusText: String {
        switch status {
        case "pending": "Held until the job is approved"
        case "releasing": "Approved · paying out"
        case "paid": "Paid"
        case "refunded": "Refunded to the poster"
        default: status.capitalized
        }
    }

    var railText: String {
        switch rail {
        case "stripe": "Stripe (USD)"
        case "usdc": "USDC on Base Sepolia"
        default: "Test payments"
        }
    }

    var amountText: String {
        currency == "USD" ? amount.formatted(.currency(code: "USD")) : "\(amount.formatted()) \(currency)"
    }
}
