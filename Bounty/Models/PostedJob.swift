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
    var poster: WorkerSummary?
    /// Signs this worker's proof captures (`CaptureSignature`). Only sent to the assigned worker while the job is in progress.
    var captureKey: String?
    var allowedActions: [String]?

    /// Ratings left after the job closed. `nil` until the backend sends them.
    var ratings: JobRatings?

    // Extension fields (`docs/API.md`, "The Job object"). Optional so sample data and older payloads decode.
    /// `poster`, `worker`, `offered` or `admin`.
    var myRole: String?
    var estMinutes: Int?
    /// What Bounty checks before paying, and what it records about the worker (`docs/API.md`, "Verification plan").
    var verification: VerificationPlan?
    /// In-person jobs: how far from the address the worker was when they started.
    var startCheck: StartCheck?
    /// The escrow's risk, for the poster (backend/src/domain/risk.ts).
    var risk: EscrowRisk?
    var feeAmount: Decimal?
    var totalAmount: Decimal?
    var attempts: ProofAttempts?
    var review: JobReview?
    var payment: JobPayment?

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
        distanceMiles: Double? = nil,
        poster: WorkerSummary? = nil,
        captureKey: String? = nil,
        allowedActions: [String]? = nil
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
        self.poster = poster
        self.captureKey = captureKey
        self.allowedActions = allowedActions
    }

    var isRemote: Bool { location == nil }

    /// Whether the server offers this action to the signed-in user (`allowedActions`).
    func allows(_ action: String) -> Bool { allowedActions?.contains(action) ?? false }

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

    var displayJob: Job {
        let cents = NSDecimalNumber(decimal: payAmount * 100).intValue
        return Job(
            id: id,
            title: title,
            pay: cents / 100,
            location: distanceText,
            deadline: deadlineText,
            sticker: PostDraft.sticker(for: category.displayName),
            tileColor: PostDraft.tileColor(for: category.displayName),
            status: JobStatus.api(status.rawValue),
            currency: currency.rawValue,
            payCents: cents
        )
    }

    /// The poster's rating of the worker, once given.
    var posterRating: JobRating? { ratings?.byPoster }

    /// The poster can rate once the job is closed, if someone worked on it and they haven't yet.
    var canRateWorker: Bool {
        (status == .released || status == .refunded) && worker != nil && posterRating == nil
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

/// The location check when the worker tapped Start (`POST /jobs/{id}/start`).
struct StartCheck: Codable, Hashable, Sendable {
    let distanceM: Int
    let accuracyM: Int?
    let at: Date

    /// "Started 35 m from the address (±8 m) at 3:02 PM"
    var summary: String {
        let accuracy = accuracyM.map { " (\u{00B1}\($0) m)" } ?? ""
        return "Started \(distanceM) m from the address\(accuracy) at \(at.formatted(date: .omitted, time: .shortened))"
    }
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
    /// `nil` reads as required, the server's default.
    var required: Bool?
    /// Photo items that need a "before" shot as well as the result.
    var beforeAfter: Bool?
    /// How to frame the photo, e.g. "Straight on, whole design in frame".
    var angleHint: String?

    init(
        id: String = UUID().uuidString,
        text: String,
        evidenceType: EvidenceType,
        photoCount: Int? = nil,
        required: Bool? = true,
        beforeAfter: Bool? = false,
        angleHint: String? = nil
    ) {
        self.id = id
        self.text = text
        self.evidenceType = evidenceType
        self.photoCount = evidenceType == .photo ? (photoCount ?? 1) : nil
        self.required = required
        self.beforeAfter = evidenceType == .photo ? beforeAfter : false
        self.angleHint = angleHint
    }

    var isRequired: Bool { required ?? true }
    var needsBeforePhoto: Bool { evidenceType == .photo && beforeAfter == true }
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

/// How a job's completion is verified, worked out by the backend from the job and its checklist.
/// One escrow's credit risk: EL = PD x LGD x EAD, a tier, and the assigned worker's trust.
struct EscrowRisk: Codable, Hashable, Sendable {
    struct WorkerTrust: Codable, Hashable, Sendable {
        let trust: Double
        let conservative: Double
        let ratedJobs: Double
    }

    /// A (safest) to E.
    let tier: String
    /// `card` or `usdc`.
    let rail: String
    let exposure: Double
    let probabilityOfLoss: Double
    let lossGivenDefault: Double
    let expectedLoss: Double
    let worker: WorkerTrust?
    let posterDisputeProbability: Double
}

/// GET /me/trust: the worker's trust score and the escrow it lets them hold at once.
struct WorkerTrustScore: Codable, Hashable, Sendable {
    let score: Double
    let conservative: Double
    let effectiveJobs: Double
    let exposureLimit: Double
    let openExposure: Double
}

struct VerificationPlan: Codable, Hashable, Sendable {
    struct Signal: Codable, Hashable, Sendable, Identifiable {
        /// `on_site_start`, `on_site_check_in`, `photo_location`, `fresh_photos`, `before_after`, `deliverable`, `deadline`, `ai_review`.
        let id: String
        /// `start`, `proof` or `review`.
        let stage: String
        /// `blocks`, `fails_item` or `poster_reviews`.
        let enforcement: String
        let title: String
        let detail: String
        /// What is recorded about the worker for this check, if anything.
        let collects: String?
    }

    let summary: String
    let signals: [Signal]
    let privacy: String
}

struct ProofItem: Codable, Hashable, Sendable {
    let checklistItemId: String
    var photoURLs: [URL] = []
    var beforePhotoURLs: [URL]?
    var afterPhotoURLs: [URL]?
    var link: URL?
    var fileURLs: [URL]?
    var checkedInAt: Date?
    /// Short clips from the worker's Bounty camera.
    var videoURLs: [URL]?
}

/// The vision model's grade for one checklist item (plan feature 26).
struct Verdict: Codable, Hashable, Sendable {
    let checklistItemId: String
    var pass: Bool
    /// 0.0 to 1.0
    var confidence: Double
    var explanation: String
    /// `pass`, `fail` or `unclear`.
    var verdict: String?
}

/// `attempts`: failed AI reviews so far, and how many retries the worker gets (US-43).
struct ProofAttempts: Codable, Hashable, Sendable {
    var failed: Int
    var maxRetries: Int

    var retriesLeft: Int { max(0, maxRetries - failed) }
}

/// `review`: the AI's overall result once grading finishes.
struct JobReview: Codable, Hashable, Sendable {
    var decision: String?
    var summary: String?
    var requiresPosterAction: Bool?
    var windowEndsAt: Date?
}

/// `payment.status`: `unpaid`, `held`, `releasing`, `paid`, `refunding` or `refunded`.
struct JobPayment: Codable, Hashable, Sendable {
    var status: String

    var displayName: String {
        switch status {
        case "unpaid": "Not funded"
        case "held": "Held in escrow"
        case "releasing": "Paying out"
        case "paid": "Paid"
        case "refunding": "Refunding"
        case "refunded": "Refunded"
        default: status.capitalized
        }
    }
}

/// One row of `GET /jobs/{id}/timeline` (US-17/49).
struct TimelineEntry: Codable, Hashable, Identifiable, Sendable {
    let seq: Int
    let type: String
    let status: String?
    let label: String
    /// `you`, `poster`, `worker`, `platform` or `admin`.
    let actor: String?
    let at: Date

    var id: Int { seq }
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

// MARK: - Ratings

/// `ratings` on the backend's Job: each side rates the other once, after RELEASED or REFUNDED.
struct JobRatings: Codable, Hashable, Sendable {
    var byPoster: JobRating?
    var byWorker: JobRating?
}

struct JobRating: Codable, Hashable, Sendable {
    var stars: Int
    var comment: String?
}
