import SwiftUI

struct CreateJobView: View {
    @State private var title = ""
    @State private var details = ""
    @State private var category = "Design"
    @State private var isRemote = false
    @State private var amount = 25.0
    @State private var deadline = Date().addingTimeInterval(86_400)

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
        }
        .navigationTitle("Post a job")
    }
}

#Preview {
    NavigationStack {
        CreateJobView()
    }
}
