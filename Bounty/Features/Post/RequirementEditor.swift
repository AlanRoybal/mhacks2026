import SwiftUI

/// Which requirement the edit sheet is showing.
struct EditTarget: Identifiable {
    let item: ChecklistItem
    let isNew: Bool
    var id: String { item.id }
}

/// The sheet behind each requirement's pencil on "What counts as done", also used for
/// "Add a requirement". Deleting happens here too.
struct RequirementEditor: View {
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
