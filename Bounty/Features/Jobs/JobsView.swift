import SwiftUI

struct JobsView: View {
    @EnvironmentObject private var postedJobs: PostedJobsStore
    @State private var selection = JobCollection.working

    var filteredJobs: [Job] {
        switch selection {
        case .working:
            SampleJobs.jobs.filter { [.accepted, .inProgress, .inReview].contains($0.status) }
        case .posted:
            postedJobs.fundedJobs.map(\.job)
        case .completed:
            SampleJobs.jobs.filter { $0.status == .paid }
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

            if selection == .posted, let error = postedJobs.refreshError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.footnote).foregroundStyle(.secondary)
                    Button("Check payments again") { Task { await postedJobs.refresh() } }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }

            if filteredJobs.isEmpty {
                ContentUnavailableView(
                    "No posted jobs",
                    systemImage: "tray",
                    description: Text("Jobs you post will appear here after funding.")
                )
            } else {
                List(filteredJobs) { job in
                    NavigationLink(value: job) {
                        JobListRow(job: job)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Jobs")
        .refreshable { await postedJobs.refresh() }
        .navigationDestination(for: Job.self) { job in
            JobDetailView(job: job)
        }
    }
}

private enum JobCollection: String, CaseIterable, Identifiable {
    case working = "Working"
    case posted = "Posted"
    case completed = "Completed"

    var id: String { rawValue }
}

private struct JobListRow: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.title)
                    .font(.headline)
                Spacer()
                Text(job.pay, format: .currency(code: "USD"))
                    .font(.headline)
            }
            HStack {
                Text(job.status.rawValue)
                    .foregroundStyle(BountyTheme.accent)
                Spacer()
                Text(job.deadline)
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
                    Text(job.pay, format: .currency(code: "USD"))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text(job.title)
                        .font(.title2.bold())
                    Label(job.status.rawValue, systemImage: "clock.fill")
                        .foregroundStyle(BountyTheme.accent)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Text("Why it matched")
                        .font(.headline)
                    Text(job.matchReason)
                        .foregroundStyle(.secondary)
                }
                .bountyPanel()

                VStack(alignment: .leading, spacing: 14) {
                    Text("Proof checklist")
                        .font(.headline)
                    Label("Show the finished work clearly", systemImage: "checkmark.circle")
                    Label("Include the one-time code", systemImage: "checkmark.circle")
                    Label("Submit before \(job.deadline)", systemImage: "checkmark.circle")
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
    .environmentObject(PostedJobsStore())
}
