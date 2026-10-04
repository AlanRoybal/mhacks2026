import Foundation
import Observation
import SwiftUI

/// The job being posted, shared by the three post screens (Post a job → Proof checklist → Fund).
/// Funding hands it to the Stripe checkout from the payments branch as a `FundingDraft`.
@MainActor
@Observable
final class PostDraft {
    nonisolated static let categories = ["Yard work", "Design", "Photos", "Tutoring", "Errands"]

    var title = ""
    var details = ""
    var category = "Yard work"
    var inPerson = true
    var address = ""
    /// Coordinates for `address`, set when the poster picks it from search or their location.
    /// Without them the backend places in-person jobs at a campus default.
    var location: JobLocation?
    var deadline: Date?
    /// Whole dollars, as shown on the Post screen.
    var pay: Int?

    var payCents: Int { (pay ?? 0) * 100 }
    var feeCents: Int { Int((Double(payCents) * 0.10).rounded()) }
    var totalCents: Int { payCents + feeCents }

    /// Same limits the payments server enforces, so checkout never fails on validation.
    var canFund: Bool {
        guard let pay, let deadline else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = details.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty && title.count <= 120
            && !details.isEmpty && details.count <= 4000
            && pay >= 1 && pay <= 10_000
            && deadline > .now
    }

    var deadlineText: String {
        deadline?.formatted(.dateTime.weekday(.abbreviated).hour().minute()) ?? "Choose deadline"
    }

    var sticker: Sticker { Self.sticker(for: category) }
    var tileColor: Color { Self.tileColor(for: category) }

    func fundingDraft() -> FundingDraft? {
        guard canFund, let deadline else { return nil }
        return FundingDraft(
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
}
