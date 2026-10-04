import AuthenticationServices
import SwiftUI
import TwinKit
import UniformTypeIdentifiers

/// The places a twin learns from: Gmail, a LinkedIn profile PDF (or data export), a résumé and the
/// calendar. Onboarding step 02 uses it once; the Twin tab keeps it so sources can be added or synced
/// again any time. Imports run on the server; the caller follows `GET /twin` → `ingest` for progress.
struct TwinSourcesList: View {
    @Environment(AppServices.self) private var services
    /// Server-side imports so far (`ingest.sources`, e.g. "resume_pdf", "gmail_sent").
    var importedSources: Set<String> = []
    /// Twin tab: connected sources offer "sync again". Onboarding: they just show Connected.
    var allowsResync = false
    /// True while a file uploads or Gmail is being read, so the caller can hold its own buttons.
    @Binding var isBusy: Bool
    /// An import was handed to the server; skills arrive when `ingest.status` leaves "processing".
    var onImportStarted: () -> Void = {}

    @State private var addedThisSession: Set<Source> = []
    @State private var working: Source?
    @State private var picking: Source?
    @State private var isLinkingCalendar = false
    @State private var note: String?
    @State private var error: String?

    enum Source: Hashable {
        case gmail, linkedIn, resume, calendar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            row(.gmail, title: "Gmail", detail: "Read-only \u{00B7} sent mail", workingDetail: "Reading sent mail\u{2026}") {
                StickerTile(sticker: .mail, background: BountyColor.sky)
            }
            row(.linkedIn, title: "LinkedIn profile PDF", detail: "Profile \u{2192} Save to PDF", workingDetail: "Uploading\u{2026}") {
                IconGlyph(icon: .linkedin, size: 24)
                    .foregroundStyle(BountyColor.lavenderInk)
                    .frame(width: 52, height: 52)
                    .background(BountyColor.lavenderSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            row(.resume, title: "R\u{00E9}sum\u{00E9}", detail: "PDF", workingDetail: "Uploading\u{2026}") {
                StickerTile(sticker: .book, background: BountyColor.mint)
            }
            row(.calendar, title: "Calendar", detail: calendarDetail, workingDetail: "Syncing\u{2026}") {
                StickerTile(sticker: .calendar, background: BountyColor.cream)
            }

            if let error {
                Text(error)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.red)
            } else if let note {
                Text(note)
                    .bountyType(.footnote)
                    .foregroundStyle(BountyColor.inkSecondary)
            }
        }
        .fileImporter(isPresented: isPicking(.linkedIn), allowedContentTypes: [.pdf, .zip]) { importDocument($0, as: .linkedIn) }
        .background {
            // A second file importer on the same view replaces the first, so this one hangs off a background view.
            Color.clear.fileImporter(isPresented: isPicking(.resume), allowedContentTypes: [.pdf]) { importDocument($0, as: .resume) }
        }
        .sheet(isPresented: $isLinkingCalendar) {
            CalendarLinkSheet { outcome in
                withAnimation(Motion.press) { _ = addedThisSession.insert(.calendar) }
                if case .synced(let busy) = outcome { note = Self.calendarNote(busy) }
            }
        }
        .onChange(of: working) { _, value in isBusy = value != nil }
    }

    private func row<Tile: View>(_ source: Source, title: String, detail: String, workingDetail: String, @ViewBuilder tile: () -> Tile) -> some View {
        let connected = isConnected(source)
        return SourceRow(
            title: title,
            detail: working == source ? workingDetail : connected && allowsResync ? connectedDetail(source) : detail,
            state: working == source ? .working : connected ? (allowsResync ? .resyncable : .connected) : .add,
            tile: tile
        ) { start(source) }
        .disabled(working != nil && working != source)
    }

    private var calendarDetail: String {
        let linked = services.linkedCalendars
        guard !linked.isEmpty else { return "Free/busy, stays on device" }
        return linked.count == 1 ? linked[0].title : "\(linked.count) calendars"
    }

    private func connectedDetail(_ source: Source) -> String {
        switch source {
        case .gmail: "Connected \u{00B7} read again for new skills"
        case .linkedIn, .resume: "Imported \u{00B7} upload a newer one"
        case .calendar:
            services.calendarSyncedAt.map { "\(calendarDetail) \u{00B7} synced \($0.formatted(.relative(presentation: .named)))" } ?? calendarDetail
        }
    }

    private func isConnected(_ source: Source) -> Bool {
        if addedThisSession.contains(source) { return true }
        switch source {
        case .gmail: return importedSources.contains("gmail_sent")
        case .linkedIn: return importedSources.contains("linkedin_pdf") || importedSources.contains("linkedin_zip")
        case .resume: return importedSources.contains("resume_pdf")
        case .calendar: return services.isCalendarLinked
        }
    }

    private func isPicking(_ source: Source) -> Binding<Bool> {
        Binding(get: { picking == source }, set: { if !$0, picking == source { picking = nil } })
    }

    private func start(_ source: Source) {
        error = nil
        note = nil
        switch source {
        case .gmail: connectGmail()
        case .linkedIn, .resume:
            guard services.profileIngestion != nil else { return markAdded(source) }
            picking = source
        case .calendar:
            guard services.availability != nil else { return markAdded(source) }
            if services.isCalendarLinked && allowsResync { syncCalendar() } else { isLinkingCalendar = true }
        }
    }

    private func markAdded(_ source: Source) {
        withAnimation(Motion.press) { _ = addedThisSession.insert(source) }
    }

    private func importDocument(_ result: Result<URL, Error>, as source: Source) {
        guard case .success(let url) = result else {
            if case .failure(let failure) = result { error = failure.localizedDescription }
            return
        }
        guard let ingestion = services.profileIngestion else { return markAdded(source) }
        working = source
        Task {
            defer { working = nil }
            do {
                let kind: ProfileDocumentSource = source == .resume ? .resume : url.pathExtension.lowercased() == "zip" ? .linkedInExport : .linkedInPDF
                _ = try await ingestion.ingest(fileURL: url, source: kind)
                markAdded(source)
                onImportStarted()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func connectGmail() {
        guard services.api != nil else { return markAdded(.gmail) }
        guard let gmail = services.gmail else {
            error = "Gmail isn\u{2019}t set up in this build yet."
            return
        }
        working = .gmail
        Task {
            defer { working = nil }
            do {
                try await gmail.connect(presentationContextProvider: PresentationAnchor.shared)
                markAdded(.gmail)
                onImportStarted()
            } catch GmailConnector.ConnectError.cancelled {
                return
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func syncCalendar() {
        working = .calendar
        Task {
            defer { working = nil }
            switch await services.syncCalendar() {
            case .synced(let busy): note = Self.calendarNote(busy)
            case .notLinked: isLinkingCalendar = true
            case .accessDenied: error = "Calendar access is off. Turn it on in Settings \u{203A} Privacy & Security \u{203A} Calendars."
            case .failed(let message): error = "Couldn\u{2019}t sync your calendar: \(message)"
            }
        }
    }

    private static func calendarNote(_ busy: Int) -> String {
        busy == 0 ? "Calendar synced. Nothing is booked in the next two weeks." : "Calendar synced. \(busy) busy \(busy == 1 ? "time" : "times") in the next two weeks."
    }
}

private struct SourceRow<Tile: View>: View {
    enum RowState { case add, working, connected, resyncable }

    let title: String
    let detail: String
    let state: RowState
    @ViewBuilder let tile: Tile
    let onTap: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            tile
            TitleSubtitle(title: title, subtitle: detail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                switch state {
                case .add:
                    IconButton(icon: .plus, label: "Add \(title)", size: 36, iconSize: 18, action: onTap)
                case .working:
                    ProgressView().frame(width: 36, height: 36)
                case .connected:
                    Chip(label: "Connected", tone: .mint)
                case .resyncable:
                    IconButton(icon: .refresh, label: "Sync \(title) again", size: 36, iconSize: 18, background: BountyColor.mint, foreground: BountyColor.mintInk, action: onTap)
                }
            }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
        }
        .padding(14)
        .borderedCard(radius: BountyRadius.row)
        .animation(Motion.press, value: state)
    }
}

/// Presents Google and LinkedIn sign-in sheets from the key window.
@MainActor
final class PresentationAnchor: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = PresentationAnchor()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
