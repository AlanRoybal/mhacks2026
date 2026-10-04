import Foundation
import Observation
import SwiftUI

/// The job being posted, shared by the three post screens (Post a job → Proof checklist → Fund).
/// Funding hands it to the Stripe checkout from the payments branch as a `FundingDraft`.
@MainActor
@Observable
final class PostDraft {
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

    var payCents: Int { pay * 100 }
    var feeCents: Int { Int((Double(payCents) * 0.10).rounded()) }
    var totalCents: Int { payCents + feeCents }

    /// Same limits the payments server enforces, so checkout never fails on validation.
    var canFund: Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 120
            && !details.isEmpty && details.count <= 4000
            && pay >= 1 && pay <= 10_000
            && deadline > .now
    }

    /// The first thing stopping the poster from continuing, phrased for the screen; `nil` when ready.
    var problem: String? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty { return "Add a title." }
        if title.count > 120 { return "Keep the title under 120 characters." }
        if details.isEmpty { return "Add a description so workers know what to do." }
        if details.count > 4000 { return "Shorten the description a little." }
        if inPerson && address.trimmingCharacters(in: .whitespaces).isEmpty { return "Add an address, or make it remote." }
        if deadline <= .now { return "Pick a deadline in the future." }
        if pay < 1 || pay > 10_000 { return "Pay has to be between $1 and $10,000." }
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
