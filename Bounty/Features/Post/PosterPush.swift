import Foundation
@preconcurrency import UserNotifications

/// The poster's alerts (plan step 7).
///
/// - **From the backend:** the server pushes `proof_ready`, `proof_needs_decision`, `offer_accepted`
///   and other poster events (`backend/src/push/templates.ts`) with `type` and `jobId` in the
///   payload. Tapping one opens that job: the review screen when it's waiting on the poster,
///   otherwise its timeline.
/// - **On the device:** a "review closing" reminder before payment releases on its own (the
///   backend has no such push), and, in sample-data mode only, a stand-in for `proof_ready`.
enum PosterPush {
    /// Push types the backend sends only to the poster.
    static let posterTypes: Set<String> = [
        "offer_accepted", "no_match_yet", "proof_ready", "proof_needs_decision",
        "worker_withdrew", "unmatched_refund", "refunded", reviewClosingType,
    ]

    /// Push types that go to the poster or the worker; routed as the poster's when the job is theirs.
    static let sharedTypes: Set<String> = ["resolved", "disputed", "deadline_missed"]

    /// Types that should open the review screen rather than the timeline.
    static let reviewTypes: Set<String> = ["proof_ready", "proof_needs_decision", reviewClosingType]

    static let reviewClosingType = "review_closing"

    // MARK: Review-closing reminders

    /// Schedules a reminder before each in-review job's payment releases on its own, and clears
    /// reminders for jobs that are no longer in review. Safe to call after every refresh.
    static func syncReviewReminders(for jobs: [PostedJob]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let ours = pending.filter { $0.hasPrefix(reminderPrefix) }

        var wanted: [String: UNNotificationRequest] = [:]
        for job in jobs where job.status == .inReview {
            guard let deadline = job.reviewDeadline, let fireDate = reminderDate(for: deadline) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Review closing soon"
            // A clock time, not "in 2 minutes": the text is fixed when the reminder is scheduled.
            content.body = "Payment for “\(job.title)” releases at \(deadline.formatted(date: .omitted, time: .shortened)) unless you respond."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.userInfo = ["type": reviewClosingType, "jobId": job.id]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSinceNow, repeats: false)
            let id = reminderPrefix + job.id
            wanted[id] = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        }

        center.removePendingNotificationRequests(withIdentifiers: ours.filter { wanted[$0] == nil })
        for (id, request) in wanted where !ours.contains(id) {
            try? await center.add(request)
        }
    }

    /// Short windows (2 minutes in demo mode) get a 30-second warning; real ones an hour.
    private static func reminderDate(for deadline: Date) -> Date? {
        let remaining = deadline.timeIntervalSinceNow
        let lead: TimeInterval = remaining < 10 * 60 ? 30 : 3600
        let fire = deadline.addingTimeInterval(-lead)
        return fire.timeIntervalSinceNow > 1 ? fire : nil
    }

    private static let reminderPrefix = "poster-review-closing-"

    // MARK: Sample-data stand-in

    /// With sample data there's no server to push, so the app announces new work itself.
    static func announceProofReady(for job: PostedJob) async {
        let content = UNMutableNotificationContent()
        content.title = "Proof ready for review"
        content.body = "“\(job.title)” passed AI review. Payment releases automatically if you don't respond."
        content.sound = .default
        content.userInfo = ["type": "proof_ready", "jobId": job.id]
        let request = UNNotificationRequest(identifier: "poster-proof-ready-\(job.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
