import SwiftUI

struct CreateJobView: View {
    @State private var title = ""
    @State private var details = ""
    @State private var category = "Design"
    @State private var isRemote = false
    @State private var amount: Decimal = 25
    @State private var deadline = Date().addingTimeInterval(86_400)
    @State private var checkoutDraft: FundingDraft?

    private let categories = ["Design", "Home", "Tutoring", "Photography", "Technology"]

    var body: some View {
        Form {
            Section("What needs to be done?") {
                TextField("Job title", text: $title)
                TextField("Describe the finished result", text: $details, axis: .vertical)
                    .lineLimit(4...8)
                Picker("Category", selection: $category) {
                    ForEach(categories, id: \.self) { category in
                        Text(category).tag(category)
                    }
                }
            }

            Section("Where and when") {
                Toggle("Remote job", isOn: $isRemote)
                if !isRemote {
                    Label("Current location", systemImage: "location.fill")
                }
                DatePicker("Deadline", selection: $deadline, in: Date()...)
            }

            Section("Payment") {
                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("25", value: $amount, format: .currency(code: "USD"))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                }
            }

            Section {
                Button("Generate proof checklist", action: {})
                    .frame(maxWidth: .infinity)
                    .font(.headline)
            } footer: {
                Text("Your description becomes an editable checklist before you fund the job.")
            }

            Section {
                Button("Review & fund job") {
                    checkoutDraft = FundingDraft(
                        id: UUID(), title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                        details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                        category: category, isRemote: isRemote,
                        deadline: deadline.ISO8601Format(), amountCents: NSDecimalNumber(decimal: amount * 100).intValue
                    )
                }
                .font(.headline)
                .disabled(!canFund)
            } footer: {
                Text("Review the total, including a 10% platform fee, before paying with Stripe.")
            }
        }
        .navigationTitle("Post a job")
        .sheet(item: $checkoutDraft) { draft in
            PaymentCheckoutView(draft: draft) {
                title = ""
                details = ""
                amount = 25
                deadline = Date().addingTimeInterval(86_400)
            }
        }
    }

    private var canFund: Bool {
        let cents = amount * 100
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && title.count <= 120
            && !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && details.count <= 4000
            && amount >= Decimal(50) / 100 && amount <= 10_000
            && cents == Decimal(NSDecimalNumber(decimal: cents).intValue)
            && deadline > Date()
    }
}

#Preview {
    NavigationStack {
        CreateJobView()
    }
    .environmentObject(PostedJobsStore())
}
