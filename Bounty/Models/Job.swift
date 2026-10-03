import Foundation

struct Job: Identifiable, Hashable {
    var id = UUID()
    let title: String
    let pay: Decimal
    let distance: String
    let deadline: String
    let matchReason: String
    var status: JobStatus
    var currency = "USD"
    var displayPay: String {
        currency == "USDC" ? "\(pay.formatted()) USDC" : pay.formatted(.currency(code: currency))
    }
}

enum JobStatus: String, CaseIterable, Identifiable {
    case funded = "Funded"
    case offered = "Offered"
    case accepted = "Accepted"
    case inProgress = "In progress"
    case inReview = "In review"
    case paid = "Paid"
    case refunded = "Refunded"
    case releasePending = "Payment pending"
    case refundPending = "Refund pending"
    case settlementIssue = "Payment needs review"

    static func api(_ value: String) -> JobStatus {
        switch value {
        case "accepted": .accepted
        case "in_progress": .inProgress
        case "in_review": .inReview
        case "released": .paid
        case "refunded": .refunded
        case "release_pending": .releasePending
        case "refund_pending": .refundPending
        case "settlement_issue": .settlementIssue
        default: .funded
        }
    }

    var id: String { rawValue }
}

enum SampleJobs {
    static let offer = Job(
        title: "Sketch a coffee shop logo",
        pay: 15,
        distance: "0.4 mi",
        deadline: "Today, 6:00 PM",
        matchReason: "Your illustration and brand design skills match this job.",
        status: .offered
    )

    static let jobs = [
        offer,
        Job(
            title: "Photograph a vintage desk",
            pay: 28,
            distance: "1.2 mi",
            deadline: "Tomorrow, 2:00 PM",
            matchReason: "You have product photography experience.",
            status: .accepted
        ),
        Job(
            title: "Review a calculus worksheet",
            pay: 35,
            distance: "Remote",
            deadline: "Oct 5, 8:00 PM",
            matchReason: "Your tutoring history includes calculus.",
            status: .inReview
        ),
        Job(
            title: "Create event poster concepts",
            pay: 60,
            distance: "Remote",
            deadline: "Completed",
            matchReason: "Your graphic design experience matched the brief.",
            status: .paid
        )
    ]
}
