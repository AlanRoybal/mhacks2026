import SwiftUI

/// The Post tab: describe a job, then generate and edit its proof checklist (plan features 8 and 9).
struct CreateJobView: View {
    @Environment(PosterStore.self) private var store
    @State private var model = CreateJobModel()
    @State private var isPickingLocation = false
    /// Set when the checklist comes back; pushes the checklist editor.
    @State private var draftJob: Job?
    @State private var savedJobTitle: String?

    var body: some View {
        @Bindable var model = model

        Form {
            Section("What needs to be done?") {
                TextField("Job title", text: $model.title)
                TextField("Describe the finished result", text: $model.description, axis: .vertical)
                    .lineLimit(4...8)
                Picker("Category", selection: $model.category) {
                    ForEach(JobCategory.allCases) { category in
                        Text(category.displayName).tag(category)
                    }
                }
            }

            PosterPhotosSection(model: model)

            Section("Where and when") {
                Toggle("Remote job", isOn: $model.isRemote.animation())
                if !model.isRemote {
                    Button {
                        isPickingLocation = true
                    } label: {
                        HStack {
                            Label(model.location?.address ?? "Choose location", systemImage: "location.fill")
                                .foregroundStyle(model.location == nil ? BountyTheme.accent : .primary)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                DatePicker("Deadline", selection: $model.deadline, in: Date.now...)
            }

            Section("Payment") {
                Picker("Currency", selection: $model.currency) {
                    ForEach(PayCurrency.allCases) { currency in
                        Text(currency.rawValue).tag(currency)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Amount")
                    Spacer()
                    TextField("25", value: $model.payAmount, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                    Text(model.currency.rawValue)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task {
                        draftJob = await model.generateChecklist(store: store)
                    }
                } label: {
                    HStack {
                        Spacer()
                        if model.isGenerating {
                            ProgressView()
                            Text("Writing your checklist…")
                        } else {
                            Text("Generate proof checklist")
                        }
                        Spacer()
                    }
                    .font(.headline)
                }
                .disabled(!model.canGenerate)
            } footer: {
                Text(model.blockingIssue ?? "Your description becomes an editable checklist before you fund the job.")
            }
        }
        .navigationTitle("Post a job")
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $isPickingLocation) {
            LocationPicker(location: $model.location)
        }
        .navigationDestination(item: $draftJob) { job in
            ChecklistEditorView(job: job) { saved in
                savedJobTitle = saved.title
                draftJob = nil
                model.reset()
            }
        }
        .alert("Couldn't create the job", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Checklist saved", isPresented: Binding(
            get: { savedJobTitle != nil },
            set: { if !$0 { savedJobTitle = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text("\"\(savedJobTitle ?? "")\" is saved as a draft in Jobs › Posted. It goes live once it's funded.")
        }
    }
}

#Preview {
    NavigationStack {
        CreateJobView()
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
