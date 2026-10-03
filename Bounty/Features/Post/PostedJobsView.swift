import SwiftUI

/// Navigation value for a job the signed-in user posted. Kept separate from `Job` so the
/// poster's detail screen (timeline, review) never collides with the worker's `JobDetailView`.
struct PostedJobRoute: Hashable {
    let jobId: String
}

/// The "Posted" segment of the Jobs tab: every job the user posted, ones needing action first.
struct PostedJobsList: View {
    @Environment(PosterStore.self) private var store

    var body: some View {
        List(store.sortedJobs) { job in
            NavigationLink(value: PostedJobRoute(jobId: job.id)) {
                PostedJobRow(job: job)
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.jobs.isEmpty && !store.isLoading {
                ContentUnavailableView(
                    "No posted jobs",
                    systemImage: "tray",
                    description: Text("Jobs you post will appear here.")
                )
            }
        }
        .refreshable { await store.loadJobs() }
        .task { await store.loadJobs() }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK") {}
        } message: {
            Text(store.errorMessage ?? "")
        }
    }
}

struct PostedJobRow: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.title)
                    .font(.headline)
                Spacer()
                Text(job.payText)
                    .font(.headline)
            }
            HStack {
                Text(job.status.needsPosterAction ? "\(job.status.displayName) · Needs you" : job.status.displayName)
                    .foregroundStyle(job.status.needsPosterAction ? BountyTheme.warning : BountyTheme.accent)
                Spacer()
                Text(job.worker?.name ?? job.distanceText)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 6)
    }
}

#Preview {
    NavigationStack {
        PostedJobsList()
            .navigationDestination(for: PostedJobRoute.self) { PostedJobDetailView(jobId: $0.jobId) }
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
