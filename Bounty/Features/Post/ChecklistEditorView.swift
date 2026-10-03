import SwiftUI

/// Shows the AI-generated acceptance checklist and lets the poster change it before funding
/// (plan feature 9). Both sides agree on what counts as proof before any money moves.
struct ChecklistEditorView: View {
    @Environment(PosterStore.self) private var store
    let job: Job
    /// Called with the saved job once the checklist is stored.
    let onSaved: (Job) -> Void

    @State private var items: [ChecklistItem]
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(job: Job, onSaved: @escaping (Job) -> Void) {
        self.job = job
        self.onSaved = onSaved
        _items = State(initialValue: job.checklist)
    }

    /// Why the checklist can't be saved yet, or nil when it can.
    private var blockingIssue: String? {
        if items.isEmpty { return "Add at least one item." }
        if items.contains(where: { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }) {
            return "Fill in or delete the empty item."
        }
        return nil
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(job.title).font(.headline)
                    Text("\(job.payText) · \(job.isRemote ? "Remote" : job.location?.address ?? "") · Due \(job.deadlineText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("The worker has to provide this evidence, and the AI grades it item by item. Edit anything that doesn't fit.")
            }

            Section("Proof checklist") {
                ForEach($items) { $item in
                    ChecklistItemRow(item: $item)
                }
                .onDelete { items.remove(atOffsets: $0) }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }

                Button("Add item", systemImage: "plus.circle.fill") {
                    items.append(ChecklistItem(text: "", evidenceType: .photo))
                }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if isSaving { ProgressView() } else { Text("Save checklist") }
                        Spacer()
                    }
                    .font(.headline)
                }
                .disabled(blockingIssue != nil || isSaving)
            } footer: {
                // Funding (Stripe PaymentSheet + Apple Pay) is owned by Payments and plugs in after this step.
                Text(blockingIssue ?? "Next, you'll fund the job. It isn't offered to workers until it's funded.")
            }
        }
        .navigationTitle("Checklist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            EditButton()
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

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        let cleaned = items.map { item in
            var item = item
            item.text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return item
        }
        do {
            let saved = try await store.updateChecklist(jobId: job.id, checklist: cleaned)
            onSaved(saved)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ChecklistItemRow: View {
    @Binding var item: ChecklistItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("What must be true when the job is done?", text: $item.text, axis: .vertical)
                .lineLimit(1...4)

            HStack {
                Picker("Evidence", selection: evidenceBinding) {
                    ForEach(EvidenceType.allCases) { type in
                        Label(type.displayName, systemImage: type.symbolName).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()

                Spacer()

                if item.evidenceType == .photo {
                    Stepper(
                        "\(item.photoCount ?? 1) photo\(item.photoCount == 1 ? "" : "s")",
                        value: photoCountBinding,
                        in: 1...6
                    )
                    .font(.subheadline)
                    .fixedSize()
                }
            }
        }
        .padding(.vertical, 4)
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

extension EvidenceType {
    var symbolName: String {
        switch self {
        case .photo: "camera.fill"
        case .checkIn: "mappin.and.ellipse"
        case .link: "link"
        case .file: "doc.fill"
        }
    }
}

#Preview {
    NavigationStack {
        ChecklistEditorView(job: PosterFixtures.jobs[1]) { _ in }
    }
    .environment(PosterStore(api: MockJobsAPI(stepDelay: 0)))
}
