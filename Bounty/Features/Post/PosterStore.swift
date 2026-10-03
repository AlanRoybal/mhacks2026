import Foundation
import Observation

/// The poster side's shared state. Views read from it; only it talks to `JobsAPI`.
@MainActor
@Observable
final class PosterStore {
    private(set) var jobs: [Job] = []
    private(set) var isLoading = false
    var errorMessage: String?

    let api: any JobsAPI

    init(api: any JobsAPI) {
        self.api = api
    }

    func loadJobs() async {
        isLoading = true
        defer { isLoading = false }
        do {
            jobs = try await api.myJobs()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Fetches one job and replaces it in the list. Returns the fresh copy.
    @discardableResult
    func refresh(jobId: String) async -> Job? {
        do {
            let job = try await api.job(id: jobId)
            upsert(job)
            return job
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func upsert(_ job: Job) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
    }

    /// Jobs where the poster needs to act come first, then everything else by date.
    var sortedJobs: [Job] {
        jobs.sorted { lhs, rhs in
            if lhs.status.needsPosterAction != rhs.status.needsPosterAction {
                return lhs.status.needsPosterAction
            }
            return lhs.createdAt > rhs.createdAt
        }
    }
}
