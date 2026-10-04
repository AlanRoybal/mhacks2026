import Foundation
import Observation
import TwinKit

/// State for the poster's posted jobs: the Jobs › Posted list, a posted job's timeline, and the
/// review screen. Posting and funding go through `PostDraft` and Caleb's checkout; this store
/// picks those jobs up from the backend (`GET /jobs/mine`) and handles approve and dispute.
///
/// If the backend isn't running, it switches to `MockJobsAPI` so the screens still demo.
@MainActor
@Observable
final class PosterStore {
    private(set) var jobs: [PostedJob] = []
    private(set) var isLoading = false
    /// True once a load has finished, so an empty list reads as "nothing posted", not "loading".
    private(set) var hasLoaded = false
    /// True after falling back to sample data because the backend couldn't be reached.
    private(set) var isUsingSampleData = false
    var errorMessage: String?

    private(set) var api: any JobsAPI

    init(api: any JobsAPI) {
        self.api = api
        isUsingSampleData = api is MockJobsAPI
    }

    /// The backend when a URL is configured (Config/*.xcconfig), otherwise sample data.
    /// Requests use `session`, the same signed-in account the worker screens use.
    static func live(session: (any AccessTokenProvider)?, bundle: Bundle = .main) -> PosterStore {
        let configured = (bundle.object(forInfoDictionaryKey: "BountyAPIBaseURL") as? String)
            .flatMap(URL.init(string:))
            .flatMap { $0.host() != nil ? $0 : nil }
        return PosterStore(api: configured.map { BackendJobsAPI(baseURL: $0, tokenProvider: session) } ?? MockJobsAPI())
    }

    func loadJobs() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            setJobs(try await api.myJobs())
            errorMessage = nil
        } catch {
            if fallBackIfUnreachable(error) {
                setJobs((try? await api.myJobs()) ?? [])
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Sends this device's APNs token to the backend so it can push poster alerts.
    /// Called at launch and whenever iOS hands the app a new token.
    func registerForPush(token: String) async {
        do {
            try await api.registerDevice(token: token)
        } catch {
            // Not fatal: the Posted list still refreshes while open, and reminders are local.
            _ = fallBackIfUnreachable(error)
        }
    }

    /// Replaces the list, announcing newly submitted work in sample mode and keeping the
    /// "review closing" reminders in step with what's in review.
    private func setJobs(_ fresh: [PostedJob]) {
        let previous = Dictionary(jobs.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        jobs = fresh
        afterStatusChanges(from: previous)
    }

    private func afterStatusChanges(from previous: [String: PostedJobStatus]) {
        let snapshot = jobs
        let usingSampleData = isUsingSampleData
        Task {
            if usingSampleData {
                for job in snapshot where job.status == .inReview {
                    if let before = previous[job.id], before != .inReview {
                        await PosterPush.announceProofReady(for: job)
                    }
                }
            }
            await PosterPush.syncReviewReminders(for: snapshot)
        }
    }

    /// Fetches one job and replaces it in the list. Returns the fresh copy.
    @discardableResult
    func refresh(jobId: String) async -> PostedJob? {
        do {
            let job = try await api.job(id: jobId)
            upsert(job)
            errorMessage = nil
            return job
        } catch {
            if !fallBackIfUnreachable(error) {
                errorMessage = error.localizedDescription
            }
            return nil
        }
    }

    func job(_ id: String?) -> PostedJob? {
        guard let id else { return nil }
        return jobs.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    func upsert(_ job: PostedJob) {
        let previous = Dictionary(jobs.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        afterStatusChanges(from: previous)
    }

    /// Approves submitted work. The server releases the payment; the app never moves money.
    func approve(_ job: PostedJob) async throws {
        upsert(try await api.approve(jobId: job.id))
    }

    /// Disputes submitted work. The poster must name the requirement that wasn't met.
    func dispute(_ job: PostedJob, item: ChecklistItem, note: String) async throws {
        upsert(try await api.dispute(jobId: job.id, checklistItemId: item.id, note: note))
    }

    /// Cancels a funded job before anyone accepts it. The server refunds in full (US-18).
    func cancel(_ job: PostedJob) async throws {
        upsert(try await api.cancel(jobId: job.id))
    }

    /// Every status change for one job, oldest first (US-17/49). Empty if it can't be loaded.
    func timeline(jobId: String) async -> [TimelineEntry] {
        (try? await api.timeline(jobId: jobId)) ?? []
    }

    /// Rates the worker once the job is closed. `comment` is optional; blank means none.
    func rate(_ job: PostedJob, stars: Int, comment: String) async throws {
        let trimmed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        upsert(try await api.rate(jobId: job.id, stars: stars, comment: trimmed.isEmpty ? nil : trimmed))
    }

    /// Jobs where the poster needs to act come first, then everything else by date.
    var sortedJobs: [PostedJob] {
        jobs.sorted { lhs, rhs in
            if lhs.status.needsPosterAction != rhs.status.needsPosterAction {
                return lhs.status.needsPosterAction
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    /// Switches to sample data the first time the backend can't be reached. Returns whether it did.
    private func fallBackIfUnreachable(_ error: Error) -> Bool {
        guard !isUsingSampleData, BackendJobsAPI.isUnreachable(error) else { return false }
        api = MockJobsAPI()
        isUsingSampleData = true
        return true
    }
}
