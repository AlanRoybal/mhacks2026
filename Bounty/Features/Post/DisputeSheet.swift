import SwiftUI

/// A dispute has to point at a specific requirement (plan feature 32), so it can be re-checked.
struct DisputeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let job: PostedJob
    let onSubmit: (ChecklistItem, String) async throws -> Void

    @State private var selectedId: ChecklistItem.ID?
    @State private var note = ""
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @FocusState private var isTyping: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Requirement", selection: $selectedId) {
                        Text("Choose one").tag(ChecklistItem.ID?.none)
                        ForEach(job.checklist) { item in
                            Text(item.text).tag(Optional(item.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Which requirement wasn't met?")
                }

                Section {
                    TextField("For example: the back of the lawn wasn't mowed", text: $note, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($isTyping)
                } header: {
                    Text("What's wrong")
                } footer: {
                    Text("Payment stays on hold. The AI re-checks the proof for this requirement, then a person decides.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Dispute")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") { Task { await submit() } }
                        .disabled(selectedId == nil || note.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { isTyping = false }
                }
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func submit() async {
        guard let item = job.checklist.first(where: { $0.id == selectedId }) else { return }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await onSubmit(item, note.trimmingCharacters(in: .whitespacesAndNewlines))
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

extension Verdict {
    /// Below this confidence, a pass is shown as "Likely met" and flagged for a closer look.
    static let reviewThreshold = 0.75
}
