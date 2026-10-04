import Foundation
import Observation
import SwiftUI

/// The job being posted, shared by the three post screens (Post a job → Proof checklist → Fund).
/// Funding hands it to the Stripe checkout from the payments branch as a `FundingDraft`.
@MainActor
@Observable
final class PostDraft {
    nonisolated static let categories = ["Yard work", "Design", "Photos", "Tutoring", "Errands"]
    var customCategories: [String] = UserDefaults.standard.stringArray(forKey: "post.customCategories") ?? [] {
        didSet { UserDefaults.standard.set(customCategories, forKey: "post.customCategories") }
    }
    var availableCategories: [String] { Self.categories + customCategories }

    enum Field: Hashable { case title, details, category, address, deadline, pay }

    func validationError(for field: Field) -> String? {
        switch field {
        case .title:
            let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return "Enter a job title." }
            if value.utf16.count > 120 { return "Keep the title to 120 characters or fewer." }
        case .details:
            let value = details.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty { return "Describe what you need done." }
            if value.utf16.count > 4000 { return "Keep the description to 4,000 characters or fewer." }
        case .category:
            let value = category.trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty || value.utf16.count > 40 { return "Choose a category of 1–40 characters." }
        case .address:
            if inPerson && address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter an address for this in-person job."
            }
        case .deadline:
            guard let deadline else { return "Choose a deadline." }
            if deadline <= .now { return "Choose a deadline in the future." }
        case .pay:
            guard let pay, (1...10_000).contains(pay) else {
                return "Enter whole-dollar pay between $1 and $10,000."
            }
        }
        return nil
    }

    /// Returns an error without changing the selection when a name is invalid.
    func addCustomCategory(_ name: String) -> String? {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf16.count <= 40 else {
            return "Enter a category of 1–40 characters."
        }
        if let existing = availableCategories.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) {
            category = existing
        } else {
            customCategories.append(value)
            category = value
        }
        return nil
    }

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

    var payCents: Int { pay.flatMap { (1...10_000).contains($0) ? $0 * 100 : nil } ?? 0 }
    var feeCents: Int { Int((Double(payCents) * 0.10).rounded()) }
    var totalCents: Int { payCents + feeCents }

    /// Shared validation for advancing the form and preparing checkout.
    var canFund: Bool {
        [Field.title, .details, .category, .address, .deadline, .pay]
            .allSatisfy { validationError(for: $0) == nil }
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

    /// Normalize built-in labels while preserving custom category names at checkout.
    nonisolated static func serverCategory(for category: String) -> String {
        switch category {
        case "Design": "Design"
        case "Photos": "Photography"
        case "Tutoring": "Tutoring"
        case "Yard work", "Errands": "Home"
        default: category.trimmingCharacters(in: .whitespacesAndNewlines)
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
