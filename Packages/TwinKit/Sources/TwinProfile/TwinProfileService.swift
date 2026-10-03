import Foundation
import TwinModels
import TwinNetworking

public struct TwinProfileService: Sendable {
    private let api: APIClient

    public init(api: APIClient) {
        self.api = api
    }

    public func profile() async throws -> TwinProfile {
        try await api.request(.get, "profile/twin")
    }

    public func update(skills: [TwinSkill]) async throws -> TwinProfile {
        try await api.request(
            .put,
            "profile/twin/skills",
            body: UpdateTwinSkillsRequest(skills: skills)
        )
    }
}

public struct UpdateTwinSkillsRequest: Codable, Equatable, Sendable {
    public let skills: [TwinSkill]

    public init(skills: [TwinSkill]) {
        self.skills = skills
    }
}
