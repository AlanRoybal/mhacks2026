import SwiftUI

/// Step 1 of posting: describe the job (plan feature 8). Layout follows the Figma
/// "Post a job" screen; styling comes later from iOS-A's design system.
struct CreateJobView: View {
    @Environment(PosterStore.self) private var store
    @State private var model = CreateJobModel()
    @State private var isPickingLocation = false
    /// Set when the AI checklist comes back; pushes step 2.
    @State private var draftJob: Job?
    @State private var fundedJobTitle: String?

    var body: some View {
        @Bindable var model = model

        Form {
            PosterPhotosSection(model: model)

            Section("Title") {
                TextField("Mow my front lawn", text: $model.title)
            }

            Section("Description") {
                TextField("Describe the finished result", text: $model.description, axis: .vertical)
                    .lineLimit(3...8)
            }

            Section("Category") {
                CategoryChips(selection: $model.category)
            }

            Section("Where") {
                Picker("Where", selection: $model.isRemote.animation()) {
                    Text("In person").tag(false)
                    Text("Remote").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if !model.isRemote {
                    Button {
                        isPickingLocation = true
                    } label: {
                        Label(model.location?.address ?? "Add the address", systemImage: "mappin.and.ellipse")
                            .foregroundStyle(model.location == nil ? .secondary : .primary)
                            .lineLimit(1)
                    }
                }
            }

            Section("Deadline and pay") {
                DatePicker("Deadline", selection: $model.deadline, in: Date.now...)

                HStack {
                    Text("Pay")
                    Spacer()
                    TextField("40", value: $model.payAmount, format: .number.precision(.fractionLength(0...2)))
                        .multilineTextAlignment(.trailing)
                        .keyboardType(.decimalPad)
                        .frame(maxWidth: 120)
                    Picker("Currency", selection: $model.currency) {
                        ForEach(PayCurrency.allCases) { currency in
                            Text(currency.rawValue).tag(currency)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
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
                            Text("Drafting your checklist…")
                        } else {
                            Label("Draft the proof checklist", systemImage: "sparkles")
                        }
                        Spacer()
                    }
                    .font(.headline)
                }
                .disabled(!model.canGenerate)
            } footer: {
                Text(model.blockingIssue ?? "AI turns your description into a checklist you can edit before funding.")
            }
        }
        .navigationTitle("Post a job")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("Draft")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $isPickingLocation) {
            LocationPicker(location: $model.location)
        }
        .navigationDestination(item: $draftJob) { job in
            ChecklistEditorView(job: job) { funded in
                fundedJobTitle = funded.title
                draftJob = nil // pops steps 2 and 3 back to the form
                model.reset()
            }
        }
        .alert("Couldn't draft the checklist", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Job funded", isPresented: Binding(
            get: { fundedJobTitle != nil },
            set: { if !$0 { fundedJobTitle = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text("\"\(fundedJobTitle ?? "")\" is live. Follow it in Jobs › Posted.")
        }
    }
}

/// The category chips from the design. Tapping the selected chip again keeps it selected.
private struct CategoryChips: View {
    @Binding var selection: JobCategory?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(JobCategory.allCases) { category in
                    let isSelected = selection == category
                    Button(category.displayName) {
                        selection = category
                    }
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(isSelected ? BountyTheme.accent : .secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

#Preview {
    NavigationStack {
        CreateJobView()
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
