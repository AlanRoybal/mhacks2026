import Foundation
import TwinModels

public struct CalendarSpan: Equatable, Hashable, Sendable {
    public enum Availability: Equatable, Hashable, Sendable {
        case busy
        case free
        case tentative
        case unavailable
        case unsupported
    }

    public let start: Date
    public let end: Date
    public let availability: Availability
    public let calendarID: String
    public let isAllDay: Bool

    public init(
        start: Date,
        end: Date,
        availability: Availability,
        calendarID: String,
        isAllDay: Bool = false
    ) {
        self.start = start
        self.end = end
        self.availability = availability
        self.calendarID = calendarID
        self.isAllDay = isAllDay
    }
}

public enum BusyExtractor {
    public static let defaultHorizon: TimeInterval = 14 * 24 * 60 * 60

    public static func busyBlocks(
        from spans: [CalendarSpan],
        disabledCalendarIDs: Set<String> = [],
        startingAt start: Date,
        horizon: TimeInterval = defaultHorizon
    ) -> [BusyBlock] {
        let end = start.addingTimeInterval(horizon)
        let blocks = spans
            .filter { !disabledCalendarIDs.contains($0.calendarID) && isBusy($0) }
            .compactMap { span -> BusyBlock? in
                let clippedStart = max(span.start, start)
                let clippedEnd = min(span.end, end)
                guard clippedEnd > clippedStart else { return nil }
                return BusyBlock(start: clippedStart, end: clippedEnd)
            }
        return merge(blocks)
    }

    public static func merge(_ blocks: [BusyBlock]) -> [BusyBlock] {
        var merged: [BusyBlock] = []
        for block in blocks.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, block.start <= last.end {
                last.end = max(last.end, block.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    public static func isBusy(_ span: CalendarSpan) -> Bool {
        switch span.availability {
        case .free:
            false
        case .tentative, .unsupported:
            !span.isAllDay
        case .busy, .unavailable:
            true
        }
    }
}
