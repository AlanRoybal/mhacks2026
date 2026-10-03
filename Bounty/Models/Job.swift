import Foundation
import SwiftUI

struct Job: Identifiable, Hashable {
    let id: String
    let title: String
    let pay: Int
    let location: String
    let deadline: String
    let sticker: Sticker
    let tileColor: Color
    let status: JobStatus
}

enum JobStatus: String, CaseIterable, Identifiable {
    case offered = "Offered"
    case accepted = "Accepted"
    case inProgress = "In progress"
    case inReview = "In review"
    case paid = "Paid"

    var id: String { rawValue }

    var chipTone: ChipTone {
        switch self {
        case .offered: .yellow
        case .accepted, .inProgress: .lavender
        case .inReview: .cream
        case .paid: .mint
        }
    }
}

enum SampleJobs {
    static let coffeeLogo = Job(
        id: "coffee-logo",
        title: "Sketch a coffee shop logo",
        pay: 15,
        location: "0.4 mi",
        deadline: "Today, 6 PM",
        sticker: .coffee,
        tileColor: BountyColor.cream,
        status: .offered
    )

    static let vintageDesk = Job(
        id: "vintage-desk",
        title: "Photograph a vintage desk",
        pay: 28,
        location: "1.2 mi",
        deadline: "Tomorrow, 2 PM",
        sticker: .camera,
        tileColor: BountyColor.grey,
        status: .accepted
    )

    static let calculus = Job(
        id: "calculus",
        title: "Review a calculus worksheet",
        pay: 35,
        location: "Remote",
        deadline: "Oct 5, 8 PM",
        sticker: .book,
        tileColor: BountyColor.sky,
        status: .inReview
    )

    static let poster = Job(
        id: "poster",
        title: "Event poster concepts",
        pay: 60,
        location: "Remote",
        deadline: "Paid Oct 1",
        sticker: .poster,
        tileColor: BountyColor.lavender,
        status: .paid
    )

    static let working = [coffeeLogo, vintageDesk, calculus, poster]

    static let lawn = Job(
        id: "lawn",
        title: "Mow my front lawn",
        pay: 40,
        location: "1200 S University Ave",
        deadline: "Sun 12 PM",
        sticker: .mower,
        tileColor: BountyColor.mint,
        status: .inReview
    )

    static let posted = [lawn]
}
