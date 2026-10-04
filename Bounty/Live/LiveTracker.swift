import ActivityKit
import CoreLocation
import Foundation
import Observation
import TwinKit

/// `GET /jobs/{id}/live`: the job's live session in SpacetimeDB, as the backend reads it back.
struct LiveSessionView: Decodable, Sendable, Equatable {
    struct Event: Decodable, Sendable, Equatable, Identifiable {
        let at: Date
        let kind: String
        let detail: String
        var id: String { "\(at.timeIntervalSince1970)-\(kind)-\(detail)" }
    }

    let provider: String
    let phase: String
    let onSiteSeconds: Int
    let timerStartEpoch: Double?
    let itemsDone: Int
    let itemsTotal: Int
    let minOnSiteSeconds: Int
    let leftSiteCount: Int
    let startedAt: Date
    let lastPingAt: Date?
    let lastDistanceM: Int?
    let signalLostCount: Int
    let radiusM: Double
    /// Newest first.
    let events: [Event]

    var content: BountyLiveAttributes.ContentState {
        .init(phase: phase, onSiteSeconds: onSiteSeconds, timerStartEpoch: timerStartEpoch, itemsDone: itemsDone,
              itemsTotal: itemsTotal, minOnSiteSeconds: minOnSiteSeconds, leftSiteCount: leftSiteCount)
    }
}

/// Runs the phone's side of a live job:
/// - for the worker, location pings while an in-person job is in progress (in the background too), so
///   SpacetimeDB can keep the on-site clock and notice leaving the site, plus proof progress;
/// - for both people, a Live Activity on the Lock Screen and in the Dynamic Island, updated here from
///   each response and by the backend's pushes when the app isn't running.
@MainActor
@Observable
final class LiveTracker {
    static let shared = LiveTracker()

    /// The latest session per job.
    private(set) var sessions: [String: LiveSessionView] = [:]
    /// Jobs whose location this phone is reporting.
    private(set) var tracking: Set<String> = []
    private(set) var locationDenied = false

    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var pinger: LocationPinger?
    @ObservationIgnored private var tokenTasks: [String: Task<Void, Never>] = [:]

    private static let pushEnv: String = {
        #if DEBUG
        "sandbox"
        #else
        "production"
        #endif
    }()

    // MARK: Session

    /// False when the job has no live session (not started yet, or started before sessions existed).
    @discardableResult
    func refresh(jobId: String, api: APIClient?) async -> Bool {
        guard let api else { return false }
        self.api = api
        guard let view: LiveSessionView = try? await api.request(.get, "jobs/\(jobId)/live") else { return false }
        apply(view, jobId: jobId)
        return true
    }

    private func apply(_ view: LiveSessionView, jobId: String) {
        sessions[jobId] = view
        Task { await updateActivities(jobId: jobId, content: view.content) }
        if !["started", "on_site", "away", "signal_lost"].contains(view.phase) { stopTracking(jobId: jobId) }
    }

    // MARK: Worker

    /// Call with every fresh copy of a job the worker has (Start, refreshes, polling). Idempotent. Once the
    /// job moves past in progress, location stops and the Live Activity follows it to review and payment.
    func work(on job: PostedJob, api: APIClient?) {
        guard let api else { return }
        guard job.status == .inProgress else {
            stopTracking(jobId: job.id)
            if hasActivity(jobId: job.id, role: "worker"), sessions[job.id]?.phase != Self.phase(of: job.status) {
                Task { await refresh(jobId: job.id, api: api) }
            }
            return
        }
        self.api = api
        if !hasActivity(jobId: job.id, role: "worker") {
            // Read the session first so the activity opens with the real clock and requirement.
            Task {
                await refresh(jobId: job.id, api: api)
                startActivity(for: job, role: "worker", counterpart: job.poster?.name)
            }
        }
        guard !job.isRemote, !tracking.contains(job.id) else { return }
        tracking.insert(job.id)
        let pinger = self.pinger ?? LocationPinger { [weak self] fix in self?.send(fix) } onDenied: { [weak self] in
            self?.locationDenied = true
        }
        self.pinger = pinger
        pinger.start()
    }

    /// The session phase a job state leads to (backend `phaseFor`), to skip refreshes that change nothing.
    private static func phase(of status: PostedJobStatus) -> String? {
        switch status {
        case .submitted: "verifying"
        case .inReview, .disputed: "in_review"
        case .released: "paid"
        case .refunded: "refunded"
        default: nil
        }
    }

    /// After a refresh of the worker's jobs: a job that's gone from the list (withdrawn, reassigned) stops
    /// reporting location and leaves the Lock Screen.
    func keepOnly(workerJobIds ids: Set<String>) {
        for jobId in tracking where !ids.contains(jobId) { stopTracking(jobId: jobId) }
        Task {
            for activity in Activity<BountyLiveAttributes>.activities where activity.attributes.role == "worker" && !ids.contains(activity.attributes.jobId) {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    func stopTracking(jobId: String) {
        tracking.remove(jobId)
        if tracking.isEmpty {
            pinger?.stop()
            pinger = nil
        }
    }

    private func send(_ fix: LocationPinger.Fix) {
        guard let api else { return }
        for jobId in tracking {
            Task {
                let body = PingBody(latitude: fix.latitude, longitude: fix.longitude, accuracyM: fix.accuracy)
                do {
                    let view: LiveSessionView = try await api.request(.post, "jobs/\(jobId)/live/ping", body: body)
                    self.apply(view, jobId: jobId)
                } catch {
                    // Usually the job moved on (proof submitted, withdrawn): read where it is now, which
                    // stops the pings and moves the Live Activity along even without a push.
                    await self.refresh(jobId: jobId, api: api)
                }
            }
        }
    }

    /// Proof captured: how many checklist items (other than check-ins) have evidence now.
    func reportProgress(jobId: String, itemsDone: Int, api: APIClient?) {
        guard let api, sessions[jobId]?.itemsDone != itemsDone else { return }
        Task {
            if let view: LiveSessionView = try? await api.request(.post, "jobs/\(jobId)/live/progress", body: ["itemsDone": itemsDone]) {
                self.apply(view, jobId: jobId)
            }
        }
    }

    // MARK: Live Activities

    var activitiesEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    func hasActivity(jobId: String, role: String) -> Bool {
        Activity<BountyLiveAttributes>.activities.contains { $0.attributes.jobId == jobId && $0.attributes.role == role && $0.activityState == .active }
    }

    /// The poster's "Track on Lock Screen".
    func follow(_ job: PostedJob, api: APIClient?) async {
        self.api = api
        await refresh(jobId: job.id, api: api)
        startActivity(for: job, role: "poster", counterpart: job.worker?.name)
    }

    func unfollow(jobId: String) async {
        for activity in Activity<BountyLiveAttributes>.activities where activity.attributes.jobId == jobId && activity.attributes.role == "poster" {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func startActivity(for job: PostedJob, role: String, counterpart: String?) {
        guard activitiesEnabled, !hasActivity(jobId: job.id, role: role) else { return }
        let content = sessions[job.id]?.content ?? .init(
            phase: job.isRemote ? "started" : "on_site", onSiteSeconds: 0, timerStartEpoch: job.isRemote ? nil : Date.now.timeIntervalSince1970,
            itemsDone: 0, itemsTotal: job.checklist.filter { $0.evidenceType != .checkIn }.count,
            minOnSiteSeconds: 0, leftSiteCount: 0
        )
        let attributes = BountyLiveAttributes(jobId: job.id, title: job.title, role: role, payText: job.payText, counterpart: counterpart)
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: content, staleDate: .now.addingTimeInterval(180)),
                pushType: .token
            )
            watchPushToken(activity, jobId: job.id, role: role)
        } catch {
            // Live Activities are off or at their limit; the in-app tracker still works.
        }
    }

    /// The backend pushes to the activity when the session changes and the app isn't running.
    private func watchPushToken(_ activity: Activity<BountyLiveAttributes>, jobId: String, role: String) {
        tokenTasks["\(jobId)-\(role)"]?.cancel()
        tokenTasks["\(jobId)-\(role)"] = Task { [weak self] in
            for await data in activity.pushTokenUpdates {
                let token = data.map { String(format: "%02x", $0) }.joined()
                guard let api = self?.api else { continue }
                try? await api.send(.post, "jobs/\(jobId)/live/activity", body: ActivityBody(token: token, env: Self.pushEnv, role: role))
            }
        }
    }

    private func updateActivities(jobId: String, content: BountyLiveAttributes.ContentState) async {
        for activity in Activity<BountyLiveAttributes>.activities where activity.attributes.jobId == jobId {
            if content.isFinished {
                await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(15 * 60)))
                tokenTasks["\(jobId)-\(activity.attributes.role)"]?.cancel()
            } else if activity.content.state != content {
                await activity.update(ActivityContent(state: content, staleDate: .now.addingTimeInterval(180)))
            }
        }
    }

    private struct PingBody: Encodable, Sendable {
        let latitude: Double
        let longitude: Double
        let accuracyM: Double
    }

    private struct ActivityBody: Encodable, Sendable {
        let token: String
        let env: String
        let role: String
    }
}

/// Location while a job is in progress, in the background too (the blue indicator shows it), sent at most
/// every 30 s. A `CLBackgroundActivitySession` keeps "While Using" permission working in the background,
/// so Bounty never asks for "Always". It stops as soon as the proof is submitted.
@MainActor
final class LocationPinger: NSObject, CLLocationManagerDelegate {
    struct Fix: Sendable {
        let latitude: Double
        let longitude: Double
        let accuracy: Double
    }

    static let interval: TimeInterval = 30

    private let manager = CLLocationManager()
    private let onFix: @MainActor (Fix) -> Void
    private let onDenied: @MainActor () -> Void
    private var background: CLBackgroundActivitySession?
    private var lastSent = Date.distantPast
    private var latest: CLLocation?
    private var heartbeat: Task<Void, Never>?

    init(onFix: @escaping @MainActor (Fix) -> Void, onDenied: @escaping @MainActor () -> Void) {
        self.onFix = onFix
        self.onDenied = onDenied
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .otherNavigation
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse: begin()
        default: onDenied()
        }
    }

    func stop() {
        heartbeat?.cancel()
        heartbeat = nil
        manager.stopUpdatingLocation()
        background?.invalidate()
        background = nil
    }

    private func begin() {
        guard background == nil else { return }
        background = CLBackgroundActivitySession()
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        // Standing still can mean no new fixes; the last one still says where the worker is.
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval))
                self?.sendIfDue(force: true)
            }
        }
    }

    private func received(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0 else { return }
        latest = location
        sendIfDue(force: false)
    }

    private func sendIfDue(force: Bool) {
        guard let latest, Date.now.timeIntervalSince(lastSent) >= (force ? Self.interval - 1 : Self.interval) else { return }
        // iOS stops delivering fixes while the phone doesn't move, so the last one still says where the
        // worker is. What SpacetimeDB treats as lost signal is the pings stopping (app killed, no network).
        lastSent = .now
        onFix(Fix(latitude: latest.coordinate.latitude, longitude: latest.coordinate.longitude, accuracy: latest.horizontalAccuracy))
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            if status == .authorizedAlways || status == .authorizedWhenInUse { self.begin() }
            else if status != .notDetermined { self.onDenied() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.received(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
