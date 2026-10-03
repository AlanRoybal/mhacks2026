import Foundation
import TwinModels
import TwinNetworking

public struct AvailabilitySyncRequest: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let windowStart: Date
    public let windowEnd: Date
    public let busyBlocks: [BusyBlock]

    public init(generatedAt: Date, windowStart: Date, windowEnd: Date, busyBlocks: [BusyBlock]) {
        self.generatedAt = generatedAt
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.busyBlocks = busyBlocks
    }

    enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case windowStart = "window_start"
        case windowEnd = "window_end"
        case busyBlocks = "busy_blocks"
    }
}

@MainActor
public final class AvailabilityService {
    private let calendar: AppleCalendarProvider
    private let api: APIClient
    private let syncPath: String

    public init(
        calendar: AppleCalendarProvider = AppleCalendarProvider(),
        api: APIClient,
        syncPath: String = "profile/availability"
    ) {
        self.calendar = calendar
        self.api = api
        self.syncPath = syncPath
    }

    public var authorizationStatus: CalendarAccessStatus {
        calendar.authorizationStatus
    }

    public func requestAccess() async -> Bool {
        await calendar.requestAccess()
    }

    public func busyBlocks(
        startingAt start: Date = .now,
        horizon: TimeInterval = BusyExtractor.defaultHorizon,
        disabledCalendarIDs: Set<String> = []
    ) -> [BusyBlock] {
        let end = start.addingTimeInterval(horizon)
        return BusyExtractor.busyBlocks(
            from: calendar.spans(from: start, to: end),
            disabledCalendarIDs: disabledCalendarIDs,
            startingAt: start,
            horizon: horizon
        )
    }

    public func sync(
        startingAt start: Date = .now,
        horizon: TimeInterval = BusyExtractor.defaultHorizon,
        disabledCalendarIDs: Set<String> = []
    ) async throws {
        let end = start.addingTimeInterval(horizon)
        let request = AvailabilitySyncRequest(
            generatedAt: .now,
            windowStart: start,
            windowEnd: end,
            busyBlocks: busyBlocks(
                startingAt: start,
                horizon: horizon,
                disabledCalendarIDs: disabledCalendarIDs
            )
        )
        try await api.send(.put, syncPath, body: request)
    }
}
