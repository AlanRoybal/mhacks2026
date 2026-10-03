import SwiftUI

/// Step 3 of posting: pay into escrow (plan feature 10). Not in the Figma yet, so this is a
/// plain summary plus one button. The job isn't offered to workers until it's funded.
struct FundJobView: View {
    @Environment(PosterStore.self) private var store
    let job: Job
    let onFunded: (Job) -> Void

    @State private var isFunding = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Step 3 of 3")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Fund the job")
                        .font(.largeTitle.bold())
                    Text("Your payment is held until you approve the work. If no one finishes by the deadline, you're refunded.")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 8, trailing: 4))
            }

            Section {
                LabeledContent("Job", value: job.title)
                LabeledContent("Where", value: job.isRemote ? "Remote" : job.location?.address ?? "")
                LabeledContent("Deadline", value: job.deadlineText)
                LabeledContent("Requirements", value: "\(job.checklist.count)")
                LabeledContent("Total", value: job.payText)
                    .font(.headline)
            }

            Section {
                Button {
                    Task { await fund() }
                } label: {
                    HStack {
                        Spacer()
                        if isFunding {
                            ProgressView()
                            Text("Confirming payment…")
                        } else {
                            Label("Fund \(job.payText)", systemImage: "lock.fill")
                        }
                        Spacer()
                    }
                    .font(.headline)
                }
                .disabled(isFunding)
            } footer: {
                Text("Paid with Apple Pay or card through Stripe. Test mode for the demo.")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isFunding)
        .alert("Payment didn't go through", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func fund() async {
        isFunding = true
        defer { isFunding = false }
        do {
            onFunded(try await store.fund(job))
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Where Payments plugs in Stripe. Replace the body of `collectPayment` with the PaymentSheet
/// flow (configure with `session.publishableKey`, present with
/// `session.paymentIntentClientSecret`, return true on `.completed`). Everything else in the
/// poster flow already calls through here.
enum PaymentHandoff {
    @MainActor
    static func collectPayment(session: FundingSession, job: Job) async throws -> Bool {
        // Mock: pretend the sheet was shown and the poster paid.
        try await Task.sleep(for: .seconds(1))
        return true
    }
}

#Preview {
    NavigationStack {
        FundJobView(job: PosterFixtures.jobs[1]) { _ in }
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
