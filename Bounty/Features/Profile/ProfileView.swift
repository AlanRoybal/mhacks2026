import SwiftUI

struct ProfileView: View {
    @Environment(AppRouter.self) private var router
    @Environment(ProfileStore.self) private var profileStore
    @State private var draft = UserProfile()
    @State private var isEditing = false
    @State private var showingDiscardConfirmation = false
    @State private var message: String?
    @State private var saveError: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name, email, phone, location, bio
    }

    var body: some View {
        BountyScreen(glow: ScreenGlow(BountyColor.glowLavender, height: 320), spacing: 16) {
            NavRow(leadingAction: goBack) {
                Text(isEditing ? "Edit profile" : "Your profile")
                    .bountyType(.bodyStrong)
                    .foregroundStyle(BountyColor.inkPrimary)
            } trailing: {
                if !isEditing {
                    IconButton(icon: .pencil, label: "Edit profile", action: beginEditing)
                        .accessibilityIdentifier("editProfileButton")
                }
            }
            .entrance(.top)

            VStack(spacing: 10) {
                InitialsAvatar(initials: profileStore.profile.initials, size: 80)
                Text(profileStore.profile.name)
                    .bountyType(.title)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .multilineTextAlignment(.center)
                Text("Your personal information")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .entrance(.top)

            if isEditing {
                editor
                    .entrance(.rest(0))
            } else {
                information
                    .entrance(.rest(0))
            }

            if let message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .bountyType(.subhead)
                    .foregroundStyle(BountyColor.mintInk)
                    .accessibilityIdentifier("profileSavedMessage")
            }

            Text("Your profile details are saved on this device.")
                .bountyType(.footnote)
                .foregroundStyle(BountyColor.inkSecondary)
                .entrance(.rest(1))
        } bottom: {
            if isEditing {
                VStack(spacing: 8) {
                    if let error = saveError ?? draft.validationMessage {
                        Text(error)
                            .bountyType(.footnote)
                            .foregroundStyle(BountyColor.red)
                            .multilineTextAlignment(.center)
                    }
                    HStack(spacing: 10) {
                        PillButton(title: "Cancel", style: .secondary, action: cancelEditing)
                        PillButton(title: "Save", icon: .check, action: save)
                            .disabled(draft.validationMessage != nil)
                            .opacity(draft.validationMessage == nil ? 1 : 0.5)
                            .accessibilityIdentifier("saveProfileButton")
                    }
                }
            } else {
                PillButton(title: "Edit profile", icon: .pencil, action: beginEditing)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .confirmationDialog("Discard your unsaved changes?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { router.back() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 16) {
            infoRow("Name", value: profileStore.profile.name)
            Divider()
            infoRow("Email", value: profileStore.profile.email)
            Divider()
            infoRow("Phone", value: profileStore.profile.phone)
            Divider()
            infoRow("Location", value: profileStore.profile.location)
            Divider()
            infoRow("About you", value: profileStore.profile.bio)
        }
        .padding(20)
        .borderedCard()
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Name", placeholder: "Your full name", text: $draft.name, focus: .name)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
            field("Email", placeholder: "you@example.com", text: $draft.email, focus: .email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            field("Phone", placeholder: "Add a phone number", text: $draft.phone, focus: .phone)
                .textContentType(.telephoneNumber)
                .keyboardType(.phonePad)
            field("Location", placeholder: "City, state", text: $draft.location, focus: .location)
                .textContentType(.addressCityAndState)
                .textInputAutocapitalization(.words)
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "About you")
                TextField("About you", text: $draft.bio, prompt: Text("Tell people a little about yourself"), axis: .vertical)
                    .bountyType(.body)
                    .foregroundStyle(BountyColor.inkPrimary)
                    .lineLimit(3...6)
                    .padding(.vertical, 12)
                    .fieldBackground(height: 100)
                    .focused($focusedField, equals: .bio)
                    .accessibilityIdentifier("profileBioField")
            }
        }
    }

    private func infoRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FieldLabel(text: title)
            Text(value.isEmpty ? "Not added yet" : value)
                .bountyType(.body)
                .foregroundStyle(value.isEmpty ? BountyColor.inkTertiary : BountyColor.inkPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private func field(_ title: String, placeholder: String, text: Binding<String>, focus: Field) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: title)
            TextField(title, text: text, prompt: Text(placeholder))
                .bountyType(.body)
                .foregroundStyle(BountyColor.inkPrimary)
                .fieldBackground()
                .focused($focusedField, equals: focus)
                .accessibilityIdentifier("profile\(title)Field")
        }
    }

    private func beginEditing() {
        draft = profileStore.profile
        message = nil
        saveError = nil
        isEditing = true
    }

    private func cancelEditing() {
        focusedField = nil
        saveError = nil
        isEditing = false
    }

    private func save() {
        guard draft.validationMessage == nil else { return }
        do {
            try profileStore.save(draft)
            focusedField = nil
            isEditing = false
            message = "Changes saved"
        } catch {
            saveError = "Your changes couldn't be saved. Please try again."
        }
    }

    private func goBack() {
        focusedField = nil
        if isEditing && draft.trimmed != profileStore.profile {
            showingDiscardConfirmation = true
        } else {
            router.back()
        }
    }
}

#Preview {
    ProfileView()
        .environment(AppRouter())
        .environment(ProfileStore())
}
