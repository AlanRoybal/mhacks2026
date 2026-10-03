import SwiftUI

/// Step 2 of posting: "What counts as done" (plan feature 9). Shows the AI-drafted
/// requirements as cards; the poster edits one with its pencil, drags to reorder, or adds
/// more. Both sides agree on what counts as proof before any money moves.
struct ChecklistEditorView: View {
    @Environment(PosterStore.self) private var store
    let job: Job
    /// Called once step 3 has funded the job.
    let onFunded: (Job) -> Void

    @State private var items: [ChecklistItem]
    /// The requirement open in the edit sheet. A new, empty item when adding.
    @State private var editing: EditTarget?
    @State private var isSaving = false
    @State private var errorMessage: String?
    /// Set after a successful save; pushes step 3.
    @State private var savedJob: Job?

    init(job: Job, onFunded: @escaping (Job) -> Void) {
        self.job = job
        self.onFunded = onFunded
        _items = State(initialValue: job.checklist)
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Step 2 of 3")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("What counts as done")
                        .font(.largeTitle.bold())
                    Text("It locks once the job is funded.")
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                Label("Drafted by AI from your description. Edit anything.", systemImage: "sparkles")
                    .font(.subheadline)
                    .foregroundStyle(BountyTheme.accent)
            }

            Section {
                ForEach(items) { item in
                    RequirementRow(item: item) {
                        editing = EditTarget(item: item, isNew: false)
                    }
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }

                Button("Add a requirement", systemImage: "plus") {
                    editing = EditTarget(item: ChecklistItem(text: "", evidenceType: .photo), isNew: true)
                }
                .buttonStyle(.borderless)
            } footer: {
                if items.isEmpty {
                    Text("Add at least one requirement.")
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving { ProgressView() } else { Text("Looks right") }
                        Spacer()
                    }
                    .font(.headline)
                }
                .disabled(items.isEmpty || isSaving)
            }
        }
        // Always-visible drag handles, as in the design. Only reordering is enabled;
        // deleting happens in the edit sheet.
        .environment(\.editMode, .constant(.active))
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { target in
            RequirementEditor(item: target.item, isNew: target.isNew) { result in
                apply(result, to: target)
            }
        }
        .navigationDestination(item: $savedJob) { job in
            FundJobView(job: job, onFunded: onFunded)
        }
        .alert("Couldn't save the checklist", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func apply(_ result: RequirementEditor.Result, to target: EditTarget) {
        switch result {
        case .saved(let item):
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
        case .deleted:
            items.removeAll { $0.id == target.item.id }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            savedJob = try await store.updateChecklist(jobId: job.id, checklist: items)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Which requirement the edit sheet is showing.
private struct EditTarget: Identifiable {
    let item: ChecklistItem
    let isNew: Bool
    var id: String { item.id }
}

/// One requirement card: what must be true, and the evidence the worker owes.
private struct RequirementRow: View {
    let item: ChecklistItem
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.headline)
                Label(item.evidenceSummary, systemImage: item.evidenceType.symbolName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Edit requirement", systemImage: "pencil", action: onEdit)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}

/// The sheet behind each card's pencil, also used for "Add a requirement".
private struct RequirementEditor: View {
    enum Result {
        case saved(ChecklistItem)
        case deleted
    }

    @Environment(\.dismiss) private var dismiss
    @State private var item: ChecklistItem
    let isNew: Bool
    let onFinish: (Result) -> Void

    init(item: ChecklistItem, isNew: Bool, onFinish: @escaping (Result) -> Void) {
        _item = State(initialValue: item)
        self.isNew = isNew
        self.onFinish = onFinish
    }

    private var trimmedText: String {
        item.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("What must be true") {
                    TextField("Front lawn mowed, under 3 in", text: $item.text, axis: .vertical)
                        .lineLimit(1...4)
                }

                Section("Proof the worker provides") {
                    Picker("Evidence", selection: evidenceBinding) {
                        ForEach(EvidenceType.allCases) { type in
                            Label(type.displayName, systemImage: type.symbolName).tag(type)
                        }
                    }
                    if item.evidenceType == .photo {
                        Stepper(value: photoCountBinding, in: 1...6) {
                            Text("\(item.photoCount ?? 1) photo\(item.photoCount == 1 ? "" : "s")")
                        }
                    }
                }

                if !isNew {
                    Section {
                        Button("Delete requirement", role: .destructive) {
                            onFinish(.deleted)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New requirement" : "Edit requirement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save") {
                        var saved = item
                        saved.text = trimmedText
                        onFinish(.saved(saved))
                        dismiss()
                    }
                    .disabled(trimmedText.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Changing the evidence type also fixes up the photo count, which only applies to photos.
    private var evidenceBinding: Binding<EvidenceType> {
        Binding(
            get: { item.evidenceType },
            set: { newType in
                item.evidenceType = newType
                item.photoCount = newType == .photo ? (item.photoCount ?? 1) : nil
            }
        )
    }

    private var photoCountBinding: Binding<Int> {
        Binding(
            get: { item.photoCount ?? 1 },
            set: { item.photoCount = $0 }
        )
    }
}

extension ChecklistItem {
    /// The one-line evidence description under each requirement, e.g. "4 photos".
    var evidenceSummary: String {
        switch evidenceType {
        case .photo:
            let count = photoCount ?? 1
            return count == 1 ? "1 photo" : "\(count) photos"
        case .checkIn: return "On-site check-in, GPS and time"
        case .link: return "A link to the finished work"
        case .file: return "A file upload"
        }
    }
}

extension EvidenceType {
    var symbolName: String {
        switch self {
        case .photo: "camera"
        case .checkIn: "location"
        case .link: "link"
        case .file: "doc"
        }
    }
}

#Preview {
    NavigationStack {
        ChecklistEditorView(job: PosterFixtures.jobs[0]) { _ in }
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
