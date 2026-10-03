import SwiftUI

struct HomeView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                TwinStatusCard()
                ActiveOfferCard(job: SampleJobs.offer)

                VStack(alignment: .leading, spacing: 12) {
                    Text("In progress")
                        .font(.title2.bold())

                    NavigationLink(value: SampleJobs.jobs[1]) {
                        JobRow(job: SampleJobs.jobs[1])
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Bounty")
        .navigationDestination(for: Job.self) { job in
            JobDetailView(job: job)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: {}) {
                    Image(systemName: "person.crop.circle")
                }
                .accessibilityLabel("Account settings")
            }
        }
    }
}

private struct TwinStatusCard: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(BountyTheme.success.opacity(0.14))
                Image(systemName: "sparkles")
                    .foregroundStyle(BountyTheme.success)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                Text("Your twin is searching")
                    .font(.headline)
                Text("12 skills · Available this evening")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Circle()
                .fill(BountyTheme.success)
                .frame(width: 9, height: 9)
                .accessibilityLabel("Active")
        }
        .bountyPanel()
    }
}

private struct ActiveOfferCard: View {
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("New match")
                    .font(.headline)
                    .foregroundStyle(BountyTheme.accent)
                Spacer()
                Text("0:42")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(BountyTheme.warning)
            }

            Text(job.payText)
                .font(.system(size: 44, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 7) {
                Text(job.title)
                    .font(.title3.bold())
                Label("\(job.distanceText) · Due \(job.deadlineText)", systemImage: "location.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let matchReason = job.matchReason {
                    Text(matchReason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 12) {
                Button("Decline", action: {})
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)

                Button("View offer", action: {})
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
        }
        .bountyPanel()
    }
}

struct JobRow: View {
    let job: Job

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: job.status == .released ? "checkmark.circle.fill" : "briefcase.fill")
                .font(.title2)
                .foregroundStyle(job.status == .released ? BountyTheme.success : BountyTheme.accent)
                .frame(width: 38, height: 38)
                .background(.quaternary, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(job.title)
                    .font(.headline)
                Text(job.status.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(job.payText)
                .font(.headline)
        }
        .bountyPanel()
    }
}

#Preview {
    NavigationStack {
        HomeView()
    }
}
