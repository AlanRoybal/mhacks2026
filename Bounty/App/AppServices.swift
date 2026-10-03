import Foundation
import Observation
import TwinKit

struct BountyRuntimeConfiguration: Equatable, Sendable {
    let apiBaseURL: URL?
    let linkedInClientID: String?
    let linkedInRedirectURI: URL

    init(bundle: Bundle = .main) {
        apiBaseURL = (bundle.object(forInfoDictionaryKey: "BountyAPIBaseURL") as? String).flatMap(URL.init(string:))
        linkedInClientID = bundle.object(forInfoDictionaryKey: "BountyLinkedInClientID") as? String
        linkedInRedirectURI = URL(string: "bounty://oauth/linkedin")!
    }
}

@MainActor
@Observable
final class AppServices {
    let session: SessionStore
    let api: APIClient?
    let offers: OfferService?
    let profile: TwinProfileService?
    let profileIngestion: ProfileIngestionService?
    let availability: AvailabilityService?
    let linkedIn: LinkedInAuthenticator?

    init(configuration: BountyRuntimeConfiguration = BountyRuntimeConfiguration()) {
        let session = SessionStore()
        self.session = session

        guard let baseURL = configuration.apiBaseURL else {
            api = nil
            offers = nil
            profile = nil
            profileIngestion = nil
            availability = nil
            linkedIn = nil
            return
        }

        let api = APIClient(baseURL: baseURL, tokenProvider: session)
        self.api = api
        offers = OfferService(api: api)
        profile = TwinProfileService(api: api)
        profileIngestion = ProfileIngestionService(api: api)
        availability = AvailabilityService(api: api)

        if let clientID = configuration.linkedInClientID, !clientID.isEmpty {
            linkedIn = LinkedInAuthenticator(
                configuration: LinkedInOIDCConfiguration(
                    clientID: clientID,
                    redirectURI: configuration.linkedInRedirectURI
                ),
                api: api
            )
        } else {
            linkedIn = nil
        }
    }
}
