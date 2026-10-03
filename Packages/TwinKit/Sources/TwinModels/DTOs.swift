import Foundation

public struct AuthSession: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresAt: Date
    public let userID: String

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, userID: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.userID = userID
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresAt = "expires_at"
        case userID = "user_id"
    }
}

public struct AuthSessionResponse: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int
    public let userID: String

    public init(accessToken: String, refreshToken: String?, expiresIn: Int, userID: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.userID = userID
    }

    public func session(now: Date = .now) -> AuthSession {
        AuthSession(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: now.addingTimeInterval(TimeInterval(expiresIn)),
            userID: userID
        )
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userID = "user_id"
    }
}

public enum SkillSource: String, Codable, CaseIterable, Sendable {
    case linkedIn = "linkedin"
    case resume
    case email
    case user
}

public struct TwinSkill: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var confidence: Double
    public var source: SkillSource
    public var yearsOfExperience: Double?

    public init(
        id: String,
        name: String,
        confidence: Double,
        source: SkillSource,
        yearsOfExperience: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.confidence = confidence
        self.source = source
        self.yearsOfExperience = yearsOfExperience
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case confidence
        case source
        case yearsOfExperience = "years_of_experience"
    }
}

public struct TwinProfile: Codable, Equatable, Sendable {
    public let userID: String
    public var headline: String?
    public var skills: [TwinSkill]
    public var roles: [String]
    public var education: [String]
    public var certifications: [String]
    public var updatedAt: Date

    public init(
        userID: String,
        headline: String? = nil,
        skills: [TwinSkill],
        roles: [String] = [],
        education: [String] = [],
        certifications: [String] = [],
        updatedAt: Date
    ) {
        self.userID = userID
        self.headline = headline
        self.skills = skills
        self.roles = roles
        self.education = education
        self.certifications = certifications
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case headline
        case skills
        case roles
        case education
        case certifications
        case updatedAt = "updated_at"
    }
}

public enum JobStatus: String, Codable, CaseIterable, Sendable {
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
}

public struct JobOffer: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let jobID: String
    public let title: String
    public let amountMinor: Int
    public let currency: String
    public let reason: String
    public let estimatedMinutes: Int?
    public let travelMinutes: Int?
    public let expiresAt: Date

    public init(
        id: String,
        jobID: String,
        title: String,
        amountMinor: Int,
        currency: String,
        reason: String,
        estimatedMinutes: Int? = nil,
        travelMinutes: Int? = nil,
        expiresAt: Date
    ) {
        self.id = id
        self.jobID = jobID
        self.title = title
        self.amountMinor = amountMinor
        self.currency = currency
        self.reason = reason
        self.estimatedMinutes = estimatedMinutes
        self.travelMinutes = travelMinutes
        self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case jobID = "job_id"
        case title
        case amountMinor = "amount_minor"
        case currency
        case reason
        case estimatedMinutes = "estimated_minutes"
        case travelMinutes = "travel_minutes"
        case expiresAt = "expires_at"
    }
}

public struct BusyBlock: Codable, Equatable, Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}
