import SwiftUI

struct EarningsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 7) {
                    Text("Available")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(75, format: .currency(code: "USD"))
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                    Text("$35 pending review")
                        .font(.subheadline)
                        .foregroundStyle(BountyTheme.warning)
                }
                .frame(maxWidth: .infinity)
                .bountyPanel()

                Button("Set up payouts", action: {})
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Recent")
                        .font(.title2.bold())

                    ForEach(SampleJobs.jobs.filter { $0.status == .released || $0.status == .inReview }) { job in
                        JobRow(job: job)
                    }
                }
            }
            .padding()
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Earnings")
    }
}

#Preview {
    NavigationStack {
        EarningsView()
    }
}
