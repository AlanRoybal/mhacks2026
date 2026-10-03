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

/// Temporary poster detail screen. Proves navigation and live refresh work against the mock;
/// it becomes the status timeline in step 6 and links to the review screen in step 8.
struct PostedJobDetailView: View {
    @Environment(PosterStore.self) private var store
    let jobId: String

    private var job: Job? { store.jobs.first { $0.id == jobId } }

    var body: some View {
        List {
            if let job {
                Section {
                    LabeledContent("Status", value: job.status.displayName)
                    LabeledContent("Pay", value: job.payText)
                    LabeledContent("Deadline", value: job.deadlineText)
                    LabeledContent("Worker", value: job.worker?.name ?? "Not yet")
                }
                Section("Proof checklist") {
                    ForEach(job.checklist) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text)
                            if let verdict = job.verdict(for: item) {
                                Text("\(verdict.pass ? "Pass" : "Fail") · \(verdict.confidence.formatted(.percent.precision(.fractionLength(0)))) confident")
                                    .font(.caption)
                                    .foregroundStyle(verdict.pass ? BountyTheme.success : BountyTheme.warning)
                            } else {
                                Text(item.evidenceType.displayName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(job?.title ?? "Job")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Poll while the screen is open so status changes appear live. Fine for the demo.
            while !Task.isCancelled {
                await store.refresh(jobId: jobId)
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

#Preview {
    NavigationStack {
        PostedJobsList()
            .navigationDestination(for: PostedJobRoute.self) { PostedJobDetailView(jobId: $0.jobId) }
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
