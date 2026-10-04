import ActivityKit
import Foundation

/// A job in progress on the Lock Screen and in the Dynamic Island, for the worker doing it and the poster
/// following it. Built into both the app and the BountyWidgets extension.
///
/// `ContentState` is exactly what the backend sends (`liveContent` in backend/src/services/live.ts), both in
/// `GET /jobs/{id}/live` and in Live Activity pushes, which ActivityKit decodes with a plain JSONDecoder.
/// The on-site clock itself lives in SpacetimeDB; the widget only ticks it forward between updates.
struct BountyLiveAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// started | on_site | away | signal_lost | submitted | verifying | in_review | paid | refunded | closed
        var phase: String
        var onSiteSeconds: Int
        /// Unix seconds such that "now minus this" is the total on-site time. Set only while on site.
        var timerStartEpoch: Double?
        var itemsDone: Int
        var itemsTotal: Int
        /// On-site time the proof is expected to show. 0 for remote jobs.
        var minOnSiteSeconds: Int
        var leftSiteCount: Int
    }

    var jobId: String
    var title: String
    /// "worker" or "poster": whose phone this is on.
    var role: String
    var payText: String
    var counterpart: String?
}

extension BountyLiveAttributes.ContentState {
    var timerStart: Date? { timerStartEpoch.map { Date(timeIntervalSince1970: $0) } }

    var isOnSite: Bool { phase == "on_site" && timerStartEpoch != nil }

    var isFinished: Bool { ["paid", "refunded", "closed"].contains(phase) }

    /// The on-site requirement is met (or there isn't one).
    var metMinimum: Bool { minOnSiteSeconds == 0 || onSiteSeconds >= minOnSiteSeconds }

    /// When the requirement will be met if the worker stays on site.
    var minimumMetAt: Date? {
        guard let timerStart, minOnSiteSeconds > 0 else { return nil }
        return timerStart.addingTimeInterval(TimeInterval(minOnSiteSeconds))
    }

    /// Short status for the compact views.
    var headline: String {
        switch phase {
        case "started": "Working"
        case "on_site": "On site"
        case "away": "Away from site"
        case "signal_lost": "Location paused"
        case "submitted", "verifying": "Checking proof"
        case "in_review": "In review"
        case "paid": "Paid"
        case "refunded": "Refunded"
        case "closed": "Closed"
        default: phase.capitalized
        }
    }

    /// One line on what's happening, from the point of view of `role`.
    func detail(role: String) -> String {
        let worker = role == "worker"
        switch phase {
        case "started": return itemsTotal > 0 ? "\(itemsDone) of \(itemsTotal) proof items captured" : "Remote job in progress"
        case "on_site": return worker ? "Timer runs while you\u{2019}re at the job" : "The worker is at your address"
        case "away": return worker ? "Head back to resume the timer" : "The worker stepped away from the site"
        case "signal_lost": return worker ? "Open Bounty to resume location" : "The worker\u{2019}s location stopped updating"
        case "submitted", "verifying": return "The AI is checking the proof"
        case "in_review": return worker ? "Waiting on the poster" : "Your review is needed"
        case "paid": return worker ? "Payment released to you" : "Payment released"
        case "refunded": return "The payment was refunded"
        default: return "Job closed"
        }
    }

    static func clock(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
