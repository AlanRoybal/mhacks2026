import SwiftUI

struct JobsView: View {
    @State private var selection = JobCollection.working

    private var workerJobs: [Job] {
        switch selection {
        case .working:
            SampleJobs.jobs.filter { $0.status.isActiveForWorker }
        case .done:
            SampleJobs.jobs.filter { $0.status == .released }
        case .posted:
            []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Job collection", selection: $selection) {
                ForEach(JobCollection.allCases) { collection in
                    Text(collection.rawValue).tag(collection)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if selection == .posted {
                PostedJobsList()
            } else if workerJobs.isEmpty {
                ContentUnavailableView(
                    "No jobs here yet",
                    systemImage: "tray",
                    description: Text("Jobs you accept will appear here.")
                )
            } else {
                List(workerJobs) { job in
                    NavigationLink(value: job) {
                        JobListRow(job: job)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Jobs")
        .navigationDestination(for: Job.self) { job in
            JobDetailView(job: job)
        }
        .navigationDestination(for: PostedJobRoute.self) { route in
            PostedJobDetailView(jobId: route.jobId)
        }
    }
}

private enum JobCollection: String, CaseIterable, Identifiable {
    case working = "Working"
    case posted = "Posted"
    case done = "Done"

    var id: String { rawValue }
}

struct JobListRow: View {
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
                Text(job.status.displayName)
                    .foregroundStyle(BountyTheme.accent)
                Spacer()
                Text(job.deadlineText)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
        .padding(.vertical, 6)
    }
}

struct JobDetailView: View {
    let job: Job

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.payText)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text(job.title)
                        .font(.title2.bold())
                    Label(job.status.displayName, systemImage: "clock.fill")
                        .foregroundStyle(BountyTheme.accent)
                }

                if let matchReason = job.matchReason {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Why it matched")
                            .font(.headline)
                        Text(matchReason)
                            .foregroundStyle(.secondary)
                    }
                    .bountyPanel()
                }

                VStack(alignment: .leading, spacing: 14) {
                    Text("Proof checklist")
                        .font(.headline)
                    if job.checklist.isEmpty {
                        Label("Show the finished work clearly", systemImage: "checkmark.circle")
                        Label("Include the one-time code", systemImage: "checkmark.circle")
                    } else {
                        ForEach(job.checklist) { item in
                            Label(item.text, systemImage: "checkmark.circle")
                        }
                    }
                    Label("Submit before \(job.deadlineText)", systemImage: "checkmark.circle")
                }
                .bountyPanel()

                if job.status == .accepted {
                    Button("Start job", action: {})
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        JobsView()
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
