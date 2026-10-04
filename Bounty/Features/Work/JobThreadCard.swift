import SwiftUI
import TwinKit

/// The iMessage thread the worker's twin runs with the poster (Photon). The worker sees details the
/// poster gave, any question waiting on them, and can answer; the twin relays it. The poster sees the
/// same conversation read-only, since they talk to the twin from Messages.
struct JobThreadCard: View {
    enum Role { case worker, poster }

    @Environment(AppServices.self) private var services
    let jobId: String
    let role: Role
    /// The other person's name, for labels ("Jamie", "Alan").
    let counterpartName: String?

    @State private var thread: JobThread?
    @State private var draft = ""
    @State private var isSending = false
    @State private var error: String?
    @State private var showsAll = false
    @FocusState private var isTyping: Bool

    private var name: String { counterpartName.flatMap { $0.split(separator: " ").first.map(String.init) } ?? (role == .worker ? "the poster" : "your worker") }

    var body: some View {
        Group {
            if let thread, thread.available || !thread.messages.isEmpty {
                content(thread)
            } else if let thread, role == .worker, thread.active {
                Text("\(name.capitalizedFirst) hasn\u{2019}t turned on texts, so your twin can\u{2019}t message them. Their details are in the job above.")
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
        .task(id: jobId) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private func content(_ thread: JobThread) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                IconGlyph(icon: .mail, size: 18)
                Text(role == .worker ? "Your twin \u{00B7} \(name)" : "\(name.capitalizedFirst)\u{2019}s twin")
                    .bountyType(.bodyStrong)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Chip(label: thread.active ? "iMessage" : "Ended", tone: thread.active ? .sky : .grey)
            }
            .foregroundStyle(BountyColor.inkPrimary)

            if role == .worker, !thread.details.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From \(name)").bountyType(.subheadStrong)
                    ForEach(thread.details, id: \.self) { detail in
                        Text("\u{2022} \(detail)").bountyType(.subhead)
                    }
                }
                .foregroundStyle(BountyColor.mintInk)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tintedPanel(BountyColor.mint, radius: 14)
            }

            if let question = thread.pendingQuestion {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(name.capitalizedFirst) asked").bountyType(.subheadStrong)
                    Text(question).bountyType(.subhead)
                }
                .foregroundStyle(BountyColor.creamInk)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .tintedPanel(BountyColor.cream, radius: 14)
                .onTapGesture { isTyping = true }
            }

            let shown = showsAll ? thread.messages : Array(thread.messages.suffix(4))
            VStack(alignment: .leading, spacing: 8) {
                if thread.messages.count > shown.count {
                    Button("Show all \(thread.messages.count) messages") { withAnimation(Motion.press) { showsAll = true } }
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.lavenderInk)
                }
                ForEach(shown) { message in
                    ThreadBubble(label: label(for: message.from), text: message.text, at: message.at, isMine: isMine(message.from))
                }
                if thread.messages.isEmpty {
                    Text(role == .worker ? "Your twin will text \(name) and pass on anything only you can answer." : "Your worker\u{2019}s twin will text you here.")
                        .bountyType(.footnote)
                        .foregroundStyle(BountyColor.inkSecondary)
                }
            }

            if role == .worker, thread.active, thread.available {
                HStack(spacing: 8) {
                    TextField(thread.pendingQuestion == nil ? "Message \(name) through your twin" : "Answer \(name)", text: $draft, axis: .vertical)
                        .lineLimit(1...4)
                        .focused($isTyping)
                        .fieldBackground(height: nil)
                    IconButton(icon: isSending ? .hourglass : .navigation, label: "Send", size: 44, iconSize: 18, background: BountyColor.inkPrimary, foreground: BountyColor.inkInverse) {
                        Task { await send() }
                    }
                    .disabled(isSending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let error {
                Text(error).bountyType(.footnote).foregroundStyle(BountyColor.red)
            }
        }
        .padding(16)
        .borderedCard()
    }

    private func isMine(_ from: String) -> Bool { role == .worker ? from != "poster" : from == "poster" }

    private func label(for from: String) -> String {
        switch (from, role) {
        case ("twin", .worker): "Your twin"
        case ("twin", .poster): "\(name.capitalizedFirst)\u{2019}s twin"
        case ("worker", .worker), ("poster", .poster): "You"
        default: name.capitalizedFirst
        }
    }

    private func load() async {
        guard let api = services.api, let fresh: JobThread = try? await api.request(.get, "jobs/\(jobId)/thread") else { return }
        withAnimation(Motion.press) { thread = fresh }
    }

    private func send() async {
        guard let api = services.api else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        isSending = true
        defer { isSending = false }
        do {
            let fresh: JobThread = try await api.request(.post, "jobs/\(jobId)/thread", body: ["text": text])
            withAnimation(Motion.press) { thread = fresh }
            draft = ""
            error = nil
            isTyping = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ThreadBubble: View {
    let label: String
    let text: String
    let at: Date
    let isMine: Bool

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            Text("\(label) \u{00B7} \(at.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))")
                .bountyType(.caption)
                .foregroundStyle(BountyColor.inkTertiary)
            Text(text)
                .bountyType(.subhead)
                .foregroundStyle(isMine ? BountyColor.inkInverse : BountyColor.inkPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isMine ? BountyColor.lavender : BountyColor.pill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .accessibilityElement(children: .combine)
    }
}

struct JobThread: Decodable, Sendable {
    struct Message: Decodable, Identifiable, Sendable {
        let id: String
        /// "twin", "poster" or "worker".
        let from: String
        let text: String
        let at: Date
        let detail: String?
    }

    let available: Bool
    let active: Bool
    let messages: [Message]
    let details: [String]
    let pendingQuestion: String?
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
