import SwiftUI

struct JobsView: View {
    @EnvironmentObject private var postedJobs: PostedJobsStore
    @EnvironmentObject private var workerPayments: WorkerPayments
    @State private var selection = JobCollection.working

    var filteredJobs: [Job] {
        switch selection {
        case .working:
            workerPayments.jobs.filter { [.accepted, .inProgress, .inReview, .releasePending, .refundPending, .settlementIssue].contains($0.status) }
        case .posted:
            postedJobs.fundedJobs.map(\.job)
        case .completed:
            workerPayments.jobs.filter { [.paid, .refunded].contains($0.status) }
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
                    "No jobs yet",
                    systemImage: "tray",
                    description: Text(selection == .posted ? "Jobs you post will appear here after funding." : "Your assigned jobs and completed payments will appear here.")
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
        .refreshable { await postedJobs.refresh(); await workerPayments.refresh() }
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
                Text(job.displayPay)
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
    @EnvironmentObject private var postedJobs: PostedJobsStore
    @EnvironmentObject private var workerPayments: WorkerPayments
    @State private var refundBusy = false
    @State private var refundMessage: String?
    let job: Job
    private var currentStatus: JobStatus {
        workerPayments.jobs.first(where: { $0.id == job.id })?.status
            ?? postedJobs.fundedJobs.first(where: { $0.id == job.id }).map { JobStatus.api($0.status) } ?? job.status
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.displayPay)
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                    Text(job.title)
                        .font(.title2.bold())
                    Label(currentStatus.rawValue, systemImage: "clock.fill")
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

                if currentStatus == .accepted {
                    Button("Start job", action: {})
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                }
                if let posted = postedJobs.fundedJobs.first(where: { $0.id == job.id }), posted.fundingRail == "usdc",
                   !["released", "refunded"].contains(posted.status),
                   (posted.deadlineDate ?? .distantFuture) <= Date() {
                    Button(refundBusy ? "Confirming refund…" : "Refund expired job") { Task { await refund(posted) } }
                        .buttonStyle(.bordered)
                        .disabled(refundBusy)
                }
                if let refundMessage { Text(refundMessage).font(.footnote).foregroundStyle(.secondary) }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Job")
        .navigationBarTitleDisplayMode(.inline)
    }
    @MainActor
    private func refund(_ posted: FundedJob) async {
        refundBusy = true; refundMessage = nil
        defer { refundBusy = false }
        do {
            let api = PaymentAPI()
            let transaction: CryptoTransaction = try await api.request(path: "crypto/jobs/\(posted.id.uuidString.lowercased())/refund-transaction", method: "GET")
            let wallet = BountyWallet.shared
            try await wallet.connect()
            guard wallet.address?.lowercased() == posted.posterWallet?.lowercased() else { throw PaymentAPIError(message: "Connect the wallet that funded this job.") }
            let hash = try await wallet.send(to: transaction.to, data: transaction.data)
            let confirmed: FundedJob = try await api.request(path: "crypto/jobs/\(posted.id.uuidString.lowercased())/confirm", method: "POST",
                body: JSONEncoder().encode(["transactionHash": hash]))
            postedJobs.record(confirmed)
            refundMessage = confirmed.status == "refunded" ? "USDC refunded to your wallet." : "Refund is still being confirmed."
        } catch { refundMessage = error.localizedDescription }
    }
}

#Preview {
    NavigationStack {
        JobsView()
    }
    .environmentObject(PostedJobsStore())
    .environmentObject(WorkerPayments())
}
