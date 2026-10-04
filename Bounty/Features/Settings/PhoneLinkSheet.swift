import SwiftUI
import TwinKit

/// Links a mobile number for job texts: enter the number, Bounty texts a 6-digit code over iMessage
/// (Photon), enter the code. `POST /me/phone`, then `POST /me/phone/verify`.
struct PhoneLinkSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    var onLinked: (MeProfile) -> Void = { _ in }

    @State private var number = ""
    @State private var sentTo: String?
    @State private var code = ""
    @State private var isWorking = false
    @State private var error: String?
    @FocusState private var focused: Field?

    enum Field { case number, code }

    var body: some View {
        NavigationStack {
            Form {
                if let sentTo {
                    Section {
                        TextField("6-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focused, equals: .code)
                            .onChange(of: code) { _, value in
                                code = String(value.filter(\.isNumber).prefix(6))
                                if code.count == 6 { Task { await verify() } }
                            }
                    } header: {
                        Text("Enter the code")
                    } footer: {
                        Text("We texted it to \(sentTo). It expires in 10 minutes.")
                    }
                    Section {
                        Button("Send a new code") { Task { await sendCode() } }.disabled(isWorking)
                        Button("Use a different number") {
                            self.sentTo = nil
                            code = ""
                            focused = .number
                        }
                    }
                } else {
                    Section {
                        TextField("Mobile number", text: $number)
                            .keyboardType(.phonePad)
                            .textContentType(.telephoneNumber)
                            .focused($focused, equals: .number)
                    } header: {
                        Text("Your mobile number")
                    } footer: {
                        Text("When someone accepts a job you posted, their Bounty twin can text you over iMessage to sort out details. Approving and paying always happen in the app. Your number is never shown to workers.")
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Text updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    } else if sentTo == nil {
                        Button("Send code") { Task { await sendCode() } }
                            .disabled(number.filter(\.isNumber).count < 7)
                    } else {
                        Button("Verify") { Task { await verify() } }.disabled(code.count != 6)
                    }
                }
            }
            .onAppear { focused = .number }
        }
    }

    private func sendCode() async {
        guard let api = services.api else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let sent: CodeSent = try await api.request(.post, "me/phone", body: ["number": sentTo ?? number])
            sentTo = sent.number
            error = nil
            focused = .code
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func verify() async {
        guard let api = services.api, code.count == 6, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let me: MeProfile = try await api.request(.post, "me/phone/verify", body: ["code": code])
            onLinked(me)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            code = ""
        }
    }

    private struct CodeSent: Decodable, Sendable {
        let number: String
    }
}
