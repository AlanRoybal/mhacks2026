import SwiftUI

/// How a job looks in Alan's design system: its sticker, tile color, status chip and short price.
/// Kept apart from `PostedJob.swift` so the data model stays shaped like the backend's JSON.
extension PostedJob {
    /// "$15" for whole dollars, "$12.50" otherwise, "40 USDC" for USDC. Used on cards and rows.
    var payShort: String {
        switch currency {
        case .usd:
            let isWhole = (payAmount as NSDecimalNumber).doubleValue.truncatingRemainder(dividingBy: 1) == 0
            return payAmount.formatted(.currency(code: "USD").precision(.fractionLength(isWhole ? 0 : 2)))
        case .usdc:
            return "\(payAmount.formatted()) USDC"
        }
    }

    var sticker: Sticker {
        let title = title.lowercased()
        if title.contains("coffee") || title.contains("logo") { return .coffee }
        if title.contains("poster") { return .poster }
        if title.contains("lawn") || title.contains("mow") { return .mower }
        return category.sticker
    }

    var tileColor: Color {
        switch sticker {
        case .coffee: BountyColor.cream
        case .camera: BountyColor.grey
        case .book: BountyColor.sky
        case .poster: BountyColor.lavender
        case .mower: BountyColor.mint
        default: category.tileColor
        }
    }
}

extension JobCategory {
    var sticker: Sticker {
        switch self {
        case .home, .yardWork: .mower
        case .design: .poster
        case .photography: .camera
        case .tutoring: .book
        case .technology: .phone
        case .errands, .moving: .mail
        case .other: .check
        }
    }

    var tileColor: Color {
        switch self {
        case .home, .yardWork: BountyColor.mint
        case .design: BountyColor.lavenderSoft
        case .photography: BountyColor.grey
        case .tutoring: BountyColor.sky
        case .technology, .errands, .moving, .other: BountyColor.cream
        }
    }
}

extension PostedJobStatus {
    var chipTone: ChipTone {
        switch self {
        case .draft, .refunded: .grey
        case .funded, .offered: .yellow
        case .accepted, .inProgress: .lavender
        case .submitted, .inReview: .cream
        case .disputed: .coral
        case .released: .mint
        }
    }
}

extension ChecklistItem {
    /// The one-line evidence description under each requirement, e.g. "4 photos".
    var evidenceSummary: String {
        switch evidenceType {
        case .photo:
            let count = photoCount ?? 1
            return count == 1 ? "1 photo" : "\(count) photos"
        case .checkIn: return "On-site check-in, GPS and time"
        case .link: return "A link to the finished work"
        case .file: return "A file upload"
        }
    }
}

extension EvidenceType {
    var symbolName: String {
        switch self {
        case .photo: "camera"
        case .checkIn: "location"
        case .link: "link"
        case .file: "doc"
        }
    }
}
