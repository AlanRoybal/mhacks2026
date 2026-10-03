import SwiftUI

/// How a job looks in Alan's design system: its sticker, tile color, status chip and short price.
/// Kept apart from `Job.swift` so the data model stays shaped like the backend's JSON.
extension Job {
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
        case .yardWork: .mower
        case .design: .poster
        case .photos: .camera
        case .tutoring: .book
        case .errands: .check
        }
    }

    var tileColor: Color {
        switch self {
        case .yardWork: BountyColor.mint
        case .design: BountyColor.lavender
        case .photos: BountyColor.grey
        case .tutoring: BountyColor.sky
        case .errands: BountyColor.cream
        }
    }
}

extension JobStatus {
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
