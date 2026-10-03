import Foundation
import Observation

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
    /// True after falling back to sample data because the backend couldn't be reached.
    private(set) var isUsingSampleData = false
    var errorMessage: String?

    private(set) var api: any JobsAPI

    init(api: any JobsAPI) {
        self.api = api
        isUsingSampleData = api is MockJobsAPI
    }

    /// The backend when a URL is configured (Config/*.xcconfig), otherwise sample data.
    static func live(bundle: Bundle = .main) -> PosterStore {
        let configured = ["BountyAPIBaseURL", "BountyPaymentsBaseURL"]
            .compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            .compactMap(URL.init(string:))
            .first { $0.host() != nil }
        return PosterStore(api: configured.map { BackendJobsAPI(baseURL: $0) } ?? MockJobsAPI())
    }

    func loadJobs() async {
        isLoading = true
        defer { isLoading = false }
        do {
            jobs = try await api.myJobs()
            errorMessage = nil
        } catch {
            if fallBackIfUnreachable(error) {
                jobs = (try? await api.myJobs()) ?? []
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Fetches one job and replaces it in the list. Returns the fresh copy.
    @discardableResult
    func refresh(jobId: String) async -> PostedJob? {
        do {
            let job = try await api.job(id: jobId)
            upsert(job)
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
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    /// Approves submitted work. The server releases the payment; the app never moves money.
    func approve(_ job: PostedJob) async throws {
        upsert(try await api.approve(jobId: job.id))
    }

    /// Disputes submitted work. The poster must name the requirement that wasn't met.
    func dispute(_ job: PostedJob, item: ChecklistItem, note: String) async throws {
        upsert(try await api.dispute(jobId: job.id, checklistItemId: item.id, note: note))
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
