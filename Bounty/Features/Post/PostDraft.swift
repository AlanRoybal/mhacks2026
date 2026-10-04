import CoreLocation
import Foundation
import Observation
import SwiftUI
import UIKit

/// The job being posted, shared by the three post screens (Post a job → Proof checklist → Fund).
///
/// "Draft the proof checklist" saves it to the backend as a DRAFT job (`job`), which comes back with the
/// AI checklist. The poster edits `checklist`, it's saved before checkout, and card checkout funds that
/// same job (`POST /jobs/{id}/fund`). USDC still goes through the payments server as a `FundingDraft`.
@MainActor
@Observable
final class PostDraft {
    /// A photo the poster attached, uploaded as soon as it's picked (US-11).
    struct Photo: Identifiable {
        let id = UUID()
        let image: UIImage
        var fileURL: URL?
        var failed = false
    }

    nonisolated static let categories = ["Yard work", "Design", "Photos", "Tutoring", "Errands"]

    var title = "Mow my front lawn"
    var details = "Front yard only. Bag the clippings. The mower is in the open garage."
    var category = "Yard work"
    var inPerson = true
    var address = "1200 S University Ave"
    /// Coordinates for `address`, set when the poster picks it from search or their location.
    /// Without them the backend places in-person jobs at a campus default.
    var location: JobLocation?
    var deadline = PostDraft.nextSundayNoon()
    /// Whole dollars, as shown on the Post screen.
    var pay = 40
    var photos: [Photo] = []

    /// The backend draft, once "Draft the proof checklist" has run.
    private(set) var job: PostedJob?
    /// The poster's working copy of the AI checklist (US-14).
    var checklist: [ChecklistItem] = []
    private(set) var isSyncing = false
    var syncError: String?
    /// What the backend draft was last saved with, so edits after going back are sent again.
    private var syncedFields: NewJobDraft?

    var payCents: Int { pay * 100 }
    var feeCents: Int { Int((Double(payCents) * 0.10).rounded()) }
    var totalCents: Int { payCents + feeCents }

    /// Same limits the payments server enforces, so checkout never fails on validation.
    var canFund: Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.count >= 3 && title.count <= 80
            && !details.isEmpty && details.count <= 2000
            && pay >= 5 && pay <= 1_000
            && deadline.timeIntervalSinceNow >= 30 * 60
    }

    /// The first thing stopping the poster from continuing, phrased for the screen; `nil` when ready.
    var problem: String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count < 3 { return "Add a title." }
        if title.count > 80 { return "Keep the title under 80 characters." }
        if details.isEmpty { return "Add a description so workers know what to do." }
        if details.count > 2000 { return "Shorten the description a little." }
        if photos.contains(where: { $0.fileURL == nil && !$0.failed }) { return "Uploading photos\u{2026}" }
        if inPerson && address.trimmingCharacters(in: .whitespaces).isEmpty { return "Add an address, or make it remote." }
        if deadline.timeIntervalSinceNow < 30 * 60 { return "Pick a deadline at least 30 minutes from now." }
        if pay < 5 || pay > 1_000 { return "Pay has to be between $5 and $1,000." }
        return nil
    }

    /// Plan step 10: the demo's job in one tap.
    func fillDemo() {
        title = "Sketch a logo for a coffee shop"
        details = "On paper, by hand. Include a coffee cup and the shop name \u{201C}Blue Fern\u{201D}, readable. Photograph the finished sketch."
        category = "Design"
        inPerson = false
        address = ""
        location = nil
        pay = 15
        // 6 PM today, or tomorrow when that's under three hours away.
        let calendar = Calendar.current
        let earliest = Date.now.addingTimeInterval(3 * 3600)
        let sixToday = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: .now) ?? earliest
        deadline = sixToday >= earliest ? sixToday : calendar.date(byAdding: .day, value: 1, to: sixToday) ?? earliest
    }

    var deadlineText: String {
        deadline.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    var sticker: Sticker { Self.sticker(for: category) }
    var tileColor: Color { Self.tileColor(for: category) }

    func fundingDraft() -> FundingDraft {
        FundingDraft(
            id: UUID(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            category: Self.serverCategory(for: category),
            isRemote: !inPerson,
            deadline: deadline.ISO8601Format(),
            amountCents: payCents,
            location: inPerson ? location : nil
        )
    }

    func reset() {
        let fresh = PostDraft()
        title = ""
        details = ""
        category = fresh.category
        inPerson = fresh.inPerson
        address = ""
        location = nil
        deadline = fresh.deadline
        pay = fresh.pay
        photos = []
        job = nil
        checklist = []
        syncedFields = nil
        syncError = nil
    }

    // MARK: Backend draft

    var backendCategory: JobCategory {
        switch category {
        case "Design": .design
        case "Photos": .photography
        case "Tutoring": .tutoring
        case "Errands": .errands
        case "Yard work": .yardWork
        default: .other
        }
    }

    /// Uploads a picked photo. The job keeps up to six.
    func addPhoto(_ image: UIImage, api: any JobsAPI) async {
        guard photos.count < 6 else { return }
        let photo = Photo(image: image)
        photos.append(photo)
        guard let data = image.proofJPEG() else { return }
        let url = try? await api.upload(data, contentType: "image/jpeg")
        if let index = photos.firstIndex(where: { $0.id == photo.id }) {
            photos[index].fileURL = url
            photos[index].failed = url == nil
        }
    }

    func removePhoto(_ id: UUID) {
        photos.removeAll { $0.id == id }
    }

    /// Creates the backend draft, or updates it if the details changed since. Returns whether it worked.
    /// Changed details also get a fresh AI checklist, since the old one may no longer fit.
    func syncDraft(api: any JobsAPI) async -> Bool {
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        do {
            let fields = try await newJobFields()
            if let job {
                guard fields != syncedFields else { return true }
                _ = try await api.updateDraft(jobId: job.id, fields)
                self.job = try await api.regenerateChecklist(jobId: job.id)
            } else {
                self.job = try await api.createJob(fields)
            }
            syncedFields = fields
            checklist = self.job?.checklist ?? []
            return true
        } catch {
            syncError = error.localizedDescription
            return false
        }
    }

    /// Asks the AI for a new checklist, discarding the poster's edits.
    func regenerateChecklist(api: any JobsAPI) async {
        guard let job else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            self.job = try await api.regenerateChecklist(jobId: job.id)
            checklist = self.job?.checklist ?? []
            syncError = nil
        } catch {
            syncError = error.localizedDescription
        }
    }

    /// Saves the edited checklist before checkout (the server locks it once funded).
    func saveChecklist(api: any JobsAPI) async -> Bool {
        guard let job else { return false }
        isSyncing = true
        syncError = nil
        defer { isSyncing = false }
        do {
            self.job = try await api.updateChecklist(jobId: job.id, checklist: checklist.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty })
            checklist = self.job?.checklist ?? checklist
            return true
        } catch {
            syncError = error.localizedDescription
            return false
        }
    }

    /// The backend draft is dropped when the poster pays with USDC through the payments server instead.
    func discardBackendDraft(api: any JobsAPI) async {
        guard let job else { return }
        try? await api.deleteDraft(jobId: job.id)
        self.job = nil
        syncedFields = nil
    }

    private func newJobFields() async throws -> NewJobDraft {
        var located = location
        if inPerson && located == nil {
            // In-person jobs need coordinates for matching and check-in; look the typed address up.
            let placemark = try? await CLGeocoder().geocodeAddressString(address).first
            guard let coordinate = placemark?.location?.coordinate else {
                throw JobsAPIError.server("Couldn\u{2019}t find that address. Tap the locate button to pick it.")
            }
            located = JobLocation(latitude: coordinate.latitude, longitude: coordinate.longitude, address: address)
            location = located
        }
        return NewJobDraft(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: details.trimmingCharacters(in: .whitespacesAndNewlines),
            category: backendCategory,
            location: inPerson ? located : nil,
            deadline: deadline,
            payAmount: Decimal(pay),
            currency: .usd,
            posterPhotos: photos.compactMap(\.fileURL)
        )
    }

    /// The payments server accepts Design, Home, Tutoring, Photography and Technology.
    nonisolated static func serverCategory(for category: String) -> String {
        switch category {
        case "Design": "Design"
        case "Photos": "Photography"
        case "Tutoring": "Tutoring"
        default: "Home"
        }
    }

    nonisolated static func sticker(for category: String) -> Sticker {
        switch category {
        case "Design": .poster
        case "Photos", "Photography": .camera
        case "Tutoring": .book
        case "Technology": .phone
        case "Errands": .mail
        default: .mower
        }
    }

    nonisolated static func tileColor(for category: String) -> Color {
        switch category {
        case "Design": BountyColor.lavenderSoft
        case "Photos", "Photography": BountyColor.grey
        case "Tutoring": BountyColor.sky
        case "Technology": BountyColor.cream
        default: BountyColor.mint
        }
    }

    private static func nextSundayNoon() -> Date {
        let calendar = Calendar.current
        let sunday = calendar.nextDate(after: .now, matching: DateComponents(hour: 12, minute: 0, weekday: 1), matchingPolicy: .nextTime)
        return sunday ?? .now.addingTimeInterval(2 * 86_400)
    }
}
