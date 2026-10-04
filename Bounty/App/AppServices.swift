import AuthenticationServices
import Foundation
import Observation
import TwinKit

struct BountyRuntimeConfiguration: Equatable, Sendable {
    let apiBaseURL: URL?
    let linkedInClientID: String?
    let googleClientID: String?

    init(bundle: Bundle = .main) {
        apiBaseURL = (bundle.object(forInfoDictionaryKey: "BountyAPIBaseURL") as? String).flatMap(URL.init(string:))
        linkedInClientID = bundle.object(forInfoDictionaryKey: "BountyLinkedInClientID") as? String
        googleClientID = (bundle.object(forInfoDictionaryKey: "BountyGoogleClientID") as? String).flatMap { $0.isEmpty ? nil : $0 }
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
    let linkedIn: LinkedInServerAuthenticator?
    let gmail: GmailConnector?
    /// Calendars the user chose in "Link your calendar". Empty means no calendar is linked, and nothing
    /// is read from the phone's calendar until one is.
    private(set) var linkedCalendarIDs: Set<String>
    /// When the linked calendars' busy times were last sent to the server.
    private(set) var calendarSyncedAt: Date?

    private static let linkedCalendarsKey = "linkedCalendarIDs"
    private static let calendarSyncedAtKey = "calendarLastSyncedAt"

    init(configuration: BountyRuntimeConfiguration = BountyRuntimeConfiguration()) {
        let session = SessionStore()
        self.session = session
        linkedCalendarIDs = Set(UserDefaults.standard.stringArray(forKey: Self.linkedCalendarsKey) ?? [])
        calendarSyncedAt = UserDefaults.standard.object(forKey: Self.calendarSyncedAtKey) as? Date

        guard let baseURL = configuration.apiBaseURL else {
            api = nil
            offers = nil
            profile = nil
            profileIngestion = nil
            availability = nil
            linkedIn = nil
            gmail = nil
            return
        }

        let api = APIClient(baseURL: baseURL, tokenProvider: session)
        self.api = api
        offers = OfferService(api: api)
        profile = TwinProfileService(api: api)
        profileIngestion = ProfileIngestionService(api: api)
        availability = AvailabilityService(api: api)
        gmail = configuration.googleClientID.map { GmailConnector(clientID: $0, api: api) }

        if let clientID = configuration.linkedInClientID, !clientID.isEmpty {
            // LinkedIn rejects custom-scheme redirect URLs, so the backend runs the OAuth flow and hands the
            // session back on bounty://auth.
            linkedIn = LinkedInServerAuthenticator(startURL: baseURL.appending(path: "auth/linkedin/start"), callbackScheme: "bounty")
        } else {
            linkedIn = nil
        }
    }

    enum CalendarSyncOutcome: Equatable {
        case synced(busyBlocks: Int)
        /// No calendar linked yet: show "Link your calendar".
        case notLinked
        case accessDenied
        case failed(String)
    }

    /// Linked calendars that still exist on the phone with access on.
    var linkedCalendars: [DeviceCalendar] {
        (availability?.calendars ?? []).filter { linkedCalendarIDs.contains($0.id) }
    }

    var isCalendarLinked: Bool { !linkedCalendars.isEmpty }

    /// Every calendar that isn't linked is skipped when reading busy times.
    private var unlinkedCalendarIDs: Set<String> {
        Set((availability?.calendars ?? []).map(\.id)).subtracting(linkedCalendarIDs)
    }

    /// Busy times from the linked calendars only. Empty when nothing is linked.
    func linkedBusyBlocks(startingAt start: Date = .now, horizon: TimeInterval) -> [BusyBlock] {
        guard let availability, isCalendarLinked else { return [] }
        return availability.busyBlocks(startingAt: start, horizon: horizon, disabledCalendarIDs: unlinkedCalendarIDs)
    }

    /// Links exactly `ids` (from the picker) and syncs them.
    func linkCalendars(_ ids: Set<String>) async -> CalendarSyncOutcome {
        linkedCalendarIDs = ids
        UserDefaults.standard.set(Array(ids), forKey: Self.linkedCalendarsKey)
        return await syncCalendar()
    }

    /// Sends the next two weeks of busy times (start and end only) from the linked calendars. Never
    /// asks for access or picks calendars itself: with nothing linked it returns `.notLinked`.
    func syncCalendar() async -> CalendarSyncOutcome {
        guard let availability else { return .failed("Not connected to the Bounty server.") }
        if [.denied, .restricted, .writeOnly].contains(availability.authorizationStatus) { return .accessDenied }
        guard isCalendarLinked else { return .notLinked }
        do {
            try await availability.sync(disabledCalendarIDs: unlinkedCalendarIDs)
            let now = Date.now
            calendarSyncedAt = now
            UserDefaults.standard.set(now, forKey: Self.calendarSyncedAtKey)
            return .synced(busyBlocks: linkedBusyBlocks(horizon: BusyExtractor.defaultHorizon).count)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Stops reading the calendar and clears the busy times the server has from it.
    func unlinkCalendar() async {
        if let availability, availability.authorizationStatus == .fullAccess {
            try? await availability.sync(disabledCalendarIDs: Set(availability.calendars.map(\.id)))
        }
        forgetCalendarSync()
    }

    /// On sign-out or unlink: the next account starts with no calendar linked.
    func forgetCalendarSync() {
        linkedCalendarIDs = []
        calendarSyncedAt = nil
        UserDefaults.standard.removeObject(forKey: Self.linkedCalendarsKey)
        UserDefaults.standard.removeObject(forKey: Self.calendarSyncedAtKey)
    }

    func signInWithApple(_ credential: ASAuthorizationAppleIDCredential) async throws {
        guard let api, let tokenData = credential.identityToken,
              let identityToken = String(data: tokenData, encoding: .utf8) else {
            throw APIError.server(status: 400, code: "apple_token_missing", message: "Apple did not provide a usable identity token.")
        }
        let name = credential.fullName.map { PersonNameComponentsFormatter().string(from: $0) }
        let response: AuthSessionResponse = try await api.request(
            .post,
            "auth/apple",
            body: AppleSignInRequest(identityToken: identityToken, fullName: name?.isEmpty == false ? name : nil),
            authenticated: false
        )
        try await session.adopt(response)
    }

    func signInForDemo() async throws {
        guard let api else { return }
        let defaults = UserDefaults.standard
        let handle = defaults.string(forKey: "BountyDemoHandle") ?? "demo-worker"
        let request = DemoSignInRequest(handle: handle, displayName: handle)
        guard let host = await api.baseURL.host(), ["localhost", "127.0.0.1"].contains(host) else {
            #if DEBUG
            // Deployed stages also want the demo key. Pass it at launch (`-BountyDemoKey <key>`) so it
            // never lands in the source or the build.
            guard let key = defaults.string(forKey: "BountyDemoKey") else { return }
            var urlRequest = URLRequest(url: await api.baseURL.appending(path: "auth/demo"))
            urlRequest.httpMethod = "POST"
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue(key, forHTTPHeaderField: "x-demo-key")
            urlRequest.httpBody = try TwinJSON.encoder().encode(request)
            let (data, _) = try await URLSession.shared.data(for: urlRequest)
            try await session.adopt(try TwinJSON.decoder().decode(AuthSessionResponse.self, from: data))
            #endif
            return
        }
        let response: AuthSessionResponse = try await api.request(.post, "auth/demo", body: request, authenticated: false)
        try await session.adopt(response)
    }
}

private struct AppleSignInRequest: Encodable, Sendable {
    let identityToken: String
    let fullName: String?
}

private struct DemoSignInRequest: Encodable, Sendable {
    let handle: String
    let displayName: String
}

struct MarketplaceOffer: Decodable, Identifiable, Sendable {
    let id: String
    let jobId: String
    let status: String
    let expiresAt: Date?
    let matchReason: String
    let fit: Double
    let estMinutes: Int
    let hourlyRate: Decimal
    let distanceMiles: Double?
    let travelMinutes: Int?
}

private struct OfferEnvelope: Decodable, Sendable {
    let offer: MarketplaceOffer?
    let job: PostedJob?
}

@MainActor
@Observable
final class MarketplaceStore {
    private(set) var currentOffer: MarketplaceOffer?
    private(set) var offeredJob: PostedJob?
    private(set) var workingJobs: [PostedJob] = []
    private(set) var isLoading = false
    var errorMessage: String?
    /// The server's error code from the last accept or decline, e.g. `offer_expired` (US-26).
    private(set) var lastErrorCode: String?

    func refresh(api: APIClient?) async {
        guard let api, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let offer: OfferEnvelope = api.request(.get, "offers/current")
            async let jobs: [PostedJob] = api.request(.get, "jobs/working")
            let values = try await (offer, jobs)
            currentOffer = values.0.offer
            offeredJob = values.0.job
            workingJobs = values.1
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func respond(api: APIClient?, accept: Bool) async -> PostedJob? {
        guard let api, let offer = currentOffer else { return nil }
        isLoading = true
        defer { isLoading = false }
        do {
            let response: OfferEnvelope = try await api.request(.post, "offers/\(offer.id)/\(accept ? "accept" : "decline")")
            currentOffer = nil
            offeredJob = nil
            if let job = response.job { upsert(job) }
            errorMessage = nil
            lastErrorCode = nil
            return response.job
        } catch {
            errorMessage = error.localizedDescription
            if case .server(_, let code, _) = error as? APIError { lastErrorCode = code } else { lastErrorCode = nil }
            // The offer is over either way; stop showing it.
            if ["offer_expired", "offer_not_current", "not_enough_time"].contains(lastErrorCode) {
                currentOffer = nil
                offeredJob = nil
            }
            return nil
        }
    }

    func start(api: APIClient?, jobId: String, latitude: Double? = nil, longitude: Double? = nil, accuracyM: Double? = nil) async -> PostedJob? {
        guard let api else { return nil }
        isLoading = true
        defer { isLoading = false }
        do {
            let job: PostedJob = try await api.request(
                .post,
                "jobs/\(jobId)/start",
                body: StartJobRequest(latitude: latitude, longitude: longitude, accuracyM: accuracyM)
            )
            upsert(job)
            errorMessage = nil
            return job
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Swaps in a fresher copy of a job (after submitting proof or polling), keeping the list's order.
    func replace(_ job: PostedJob) {
        if let index = workingJobs.firstIndex(where: { $0.id == job.id }) {
            workingJobs[index] = job
        } else {
            workingJobs.insert(job, at: 0)
        }
    }

    private func upsert(_ job: PostedJob) {
        workingJobs.removeAll { $0.id == job.id }
        workingJobs.insert(job, at: 0)
    }
}

private struct StartJobRequest: Encodable, Sendable {
    let latitude: Double?
    let longitude: Double?
    /// How accurate the fix is; the server refuses one too vague to show the worker is at the address.
    let accuracyM: Double?
}
