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
            amountCents: payCents
        )
    }

    func reset() {
        let fresh = PostDraft()
        title = ""
        details = ""
        category = fresh.category
        inPerson = fresh.inPerson
        address = ""
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
