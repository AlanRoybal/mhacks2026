import Foundation
import TwinModels

public enum OfferDecision: String, Codable, Sendable {
    case accept
    case decline
}

public struct OfferResponseRequest: Codable, Equatable, Sendable {
    public let decision: OfferDecision

    public init(decision: OfferDecision) {
        self.decision = decision
    }
}

public struct OfferResponse: Codable, Equatable, Sendable {
    public let offerID: String
    public let jobID: String
    public let status: JobStatus

    public init(offerID: String, jobID: String, status: JobStatus) {
        self.offerID = offerID
        self.jobID = jobID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case offerID = "offer_id"
        case jobID = "job_id"
        case status
    }
}

public struct OfferService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    public func respond(to offerID: String, decision: OfferDecision) async throws -> OfferResponse {
        try await api.request(
            .post,
            "offers/\(offerID)/respond",
            body: OfferResponseRequest(decision: decision)
        )
    }
}
