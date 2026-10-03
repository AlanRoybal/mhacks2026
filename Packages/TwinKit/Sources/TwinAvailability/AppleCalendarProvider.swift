import EventKit
import Foundation

public enum CalendarAccessStatus: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case writeOnly
    case fullAccess
}

@MainActor
public final class AppleCalendarProvider {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    public var authorizationStatus: CalendarAccessStatus {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            .notDetermined
        case .denied:
            .denied
        case .restricted:
            .restricted
        case .writeOnly:
            .writeOnly
        case .fullAccess, .authorized:
            .fullAccess
        @unknown default:
            .denied
        }
    }

    public func requestAccess() async -> Bool {
        (try? await store.requestFullAccessToEvents()) ?? false
    }

    public func spans(from start: Date, to end: Date) -> [CalendarSpan] {
        guard authorizationStatus == .fullAccess else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarSpan(
                start: event.startDate,
                end: event.endDate,
                availability: Self.map(event.availability),
                calendarID: event.calendar.calendarIdentifier,
                isAllDay: event.isAllDay
            )
        }
    }

    private static func map(_ availability: EKEventAvailability) -> CalendarSpan.Availability {
        switch availability {
        case .busy:
            .busy
        case .free:
            .free
        case .tentative:
            .tentative
        case .unavailable:
            .unavailable
        case .notSupported:
            .unsupported
        @unknown default:
            .unsupported
        }
    }
}
