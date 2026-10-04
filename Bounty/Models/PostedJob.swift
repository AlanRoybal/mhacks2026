import Foundation

// MARK: - PostedJob

/// A job as the backend returns it (`docs/API.md`, "The Job object"), used by the poster's
/// Posted list, timeline and review screens. Fields and status values match the backend's state
/// machine; extra fields in the JSON are ignored. `Job` is the worker screens' display model.
struct PostedJob: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var description: String
    var category: JobCategory
    /// `nil` means the job is remote.
    var location: JobLocation?
    var deadline: Date
    var payAmount: Decimal
    var currency: PayCurrency
    var posterPhotos: [URL]
    var checklist: [ChecklistItem]
    var status: PostedJobStatus
    var worker: WorkerSummary?
    var proof: Proof?
    var verdicts: [Verdict]
    /// Set when the job enters IN_REVIEW. Money releases automatically after this.
    var reviewDeadline: Date?
    var createdAt: Date

    // Worker-side offer details. The server fills these in when it sends a job to a specific worker.
    /// The twin's "why you" reason.
    var matchReason: String?
    /// Distance from the worker, in miles. `nil` for remote jobs or the poster's own view.
    var distanceMiles: Double?

    init(
        id: String = UUID().uuidString,
        title: String,
        description: String = "",
        category: JobCategory = .other,
        location: JobLocation? = nil,
        deadline: Date,
        payAmount: Decimal,
        currency: PayCurrency = .usd,
        posterPhotos: [URL] = [],
        checklist: [ChecklistItem] = [],
        status: PostedJobStatus = .draft,
        worker: WorkerSummary? = nil,
        proof: Proof? = nil,
        verdicts: [Verdict] = [],
        reviewDeadline: Date? = nil,
        createdAt: Date = .now,
        matchReason: String? = nil,
        distanceMiles: Double? = nil
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.category = category
        self.location = location
        self.deadline = deadline
        self.payAmount = payAmount
        self.currency = currency
        self.posterPhotos = posterPhotos
        self.checklist = checklist
        self.status = status
        self.worker = worker
        self.proof = proof
        self.verdicts = verdicts
        self.reviewDeadline = reviewDeadline
        self.createdAt = createdAt
        self.matchReason = matchReason
        self.distanceMiles = distanceMiles
    }

    var isRemote: Bool { location == nil }

    /// The verdict for one checklist item, if the AI has graded it.
    func verdict(for item: ChecklistItem) -> Verdict? {
        verdicts.first { $0.checklistItemId == item.id }
    }
}

// MARK: - Display helpers

extension PostedJob {
    /// "$15.00" for USD, "15 USDC" for USDC.
    var payText: String {
        switch currency {
        case .usd: payAmount.formatted(.currency(code: "USD"))
        case .usdc: "\(payAmount.formatted()) USDC"
        }
    }

    /// "Remote" or "0.4 mi".
    var distanceText: String {
        if isRemote { return "Remote" }
        guard let distanceMiles else { return location?.address ?? "" }
        return "\(distanceMiles.formatted(.number.precision(.fractionLength(1)))) mi"
    }

    /// "Today, 6:00 PM", "Tomorrow, 2:00 PM", or "Oct 5, 8:00 PM".
    var deadlineText: String {
        let calendar = Calendar.current
        let time = deadline.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(deadline) { return "Today, \(time)" }
        if calendar.isDateInTomorrow(deadline) { return "Tomorrow, \(time)" }
        return deadline.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}

// MARK: - Status

/// Mirrors the server's state machine exactly. Raw values are the server's strings;
/// use `displayName` for anything shown on screen.
enum PostedJobStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case draft = "DRAFT"
    case funded = "FUNDED"
    case offered = "OFFERED"
    case accepted = "ACCEPTED"
    case inProgress = "IN_PROGRESS"
    case submitted = "SUBMITTED"
    case inReview = "IN_REVIEW"
    case disputed = "DISPUTED"
    case released = "RELEASED"
    case refunded = "REFUNDED"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .draft: "Draft"
        case .funded: "Funded"
        case .offered: "Offered"
        case .accepted: "Accepted"
        case .inProgress: "In progress"
        case .submitted: "Submitted"
        case .inReview: "In review"
        case .disputed: "Disputed"
        case .released: "Paid"
        case .refunded: "Refunded"
        }
    }

    /// True when the poster needs to do something.
    var needsPosterAction: Bool {
        self == .draft || self == .inReview
    }

    /// True when the job is finished either way.
    var isTerminal: Bool {
        self == .released || self == .refunded
    }

    /// Statuses where a worker has the job and is working on it or waiting on review.
    var isActiveForWorker: Bool {
        [.accepted, .inProgress, .submitted, .inReview, .disputed].contains(self)
    }
}

/// The six steps shown on the poster's timeline (plan feature 11).
enum TimelineStep: Int, CaseIterable, Sendable {
    case funded, offered, accepted, inProgress, submitted, paid

    var title: String {
        switch self {
        case .funded: "Funded"
        case .offered: "Offered"
        case .accepted: "Accepted"
        case .inProgress: "In progress"
        case .submitted: "Submitted"
        case .paid: "Approved / Paid"
        }
    }
}

extension PostedJobStatus {
    /// Which timeline step this status sits on. `nil` for draft and refunded jobs.
    var timelineStep: TimelineStep? {
        switch self {
        case .draft, .refunded: nil
        case .funded: .funded
        case .offered: .offered
        case .accepted: .accepted
        case .inProgress: .inProgress
        case .submitted, .inReview, .disputed: .submitted
        case .released: .paid
        }
    }
}

// MARK: - Supporting types

/// The backend's nine categories (`backend/src/domain/types.ts`). Jobs funded through the
/// checkout arrive as Design, Home, Tutoring, Photography or Technology.
enum JobCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case design = "DESIGN"
    case home = "HOME"
    case yardWork = "YARD_WORK"
    case moving = "MOVING"
    case tutoring = "TUTORING"
    case photography = "PHOTOGRAPHY"
    case technology = "TECHNOLOGY"
    case errands = "ERRANDS"
    case other = "OTHER"

    var id: String { rawValue }

    /// A category added on the server later shows as Other instead of failing the whole job.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = JobCategory(rawValue: raw) ?? .other
    }

    var displayName: String {
        switch self {
        case .design: "Design"
        case .home: "Home"
        case .yardWork: "Yard work"
        case .moving: "Moving"
        case .tutoring: "Tutoring"
        case .photography: "Photography"
        case .technology: "Technology"
        case .errands: "Errands"
        case .other: "Other"
        }
    }

    /// Categories where a "before" photo from the poster usually helps.
    var suggestsBeforePhotos: Bool {
        switch self {
        case .home, .yardWork, .moving: true
        default: false
        }
    }
}

enum PayCurrency: String, Codable, CaseIterable, Identifiable, Sendable {
    case usd = "USD"
    case usdc = "USDC"

    var id: String { rawValue }
}

struct JobLocation: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var address: String
}

struct WorkerSummary: Codable, Hashable, Sendable {
    let id: String
    var name: String
    /// Average rating out of 5, or nil for a new worker.
    var rating: Double?
}

// MARK: - Checklist

/// One objective acceptance criterion generated by the AI and editable by the poster (plan feature 9).
struct ChecklistItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var text: String
    var evidenceType: EvidenceType
    /// How many photos are required. Only used when `evidenceType == .photo`.
    var photoCount: Int?

    init(id: String = UUID().uuidString, text: String, evidenceType: EvidenceType, photoCount: Int? = nil) {
        self.id = id
        self.text = text
        self.evidenceType = evidenceType
        self.photoCount = evidenceType == .photo ? (photoCount ?? 1) : nil
    }
}

enum EvidenceType: String, Codable, CaseIterable, Identifiable, Sendable {
    case photo = "PHOTO"
    case checkIn = "CHECK_IN"
    case link = "LINK"
    case file = "FILE"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .photo: "Photo"
        case .checkIn: "Location check-in"
        case .link: "Link"
        case .file: "File"
        }
    }
}

// MARK: - Proof and grading

/// What the worker submitted, grouped by checklist item.
struct Proof: Codable, Hashable, Sendable {
    var items: [ProofItem]
    var submittedAt: Date

    func item(for checklistItem: ChecklistItem) -> ProofItem? {
        items.first { $0.checklistItemId == checklistItem.id }
    }
}

struct ProofItem: Codable, Hashable, Sendable {
    let checklistItemId: String
    var photoURLs: [URL] = []
    var link: URL?
    var checkedInAt: Date?
}

/// The vision model's grade for one checklist item (plan feature 26).
struct Verdict: Codable, Hashable, Sendable {
    let checklistItemId: String
    var pass: Bool
    /// 0.0 to 1.0
    var confidence: Double
    var explanation: String
}

// MARK: - Requests

/// What the post-job form sends to `jobs/create`. The server returns a DRAFT job with a generated checklist.
struct NewJobDraft: Codable, Hashable, Sendable {
    var title = ""
    var description = ""
    var category = JobCategory.other
    var location: JobLocation?
    var deadline = Date.now.addingTimeInterval(24 * 3600)
    var payAmount: Decimal = 25
    var currency = PayCurrency.usd
    var posterPhotos: [URL] = []
}
