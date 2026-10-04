import EventKit
import Foundation

/// A calendar the user can link, grouped in the picker by its account (`source`).
public struct DeviceCalendar: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    /// Account name, e.g. "iCloud", "Gmail" or an Exchange address.
    public let source: String
    /// sRGB components of the calendar's color.
    public let color: [Double]

    public init(id: String, title: String, source: String, color: [Double]) {
        self.id = id
        self.title = title
        self.source = source
        self.color = color
    }
}

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

    /// Event calendars on the phone (iCloud, Google, Exchange…). Empty until full access is granted.
    public var calendars: [DeviceCalendar] {
        guard authorizationStatus == .fullAccess else { return [] }
        return store.calendars(for: .event)
            .map { calendar in
                let rgb = calendar.cgColor.flatMap { $0.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) }?.components ?? [0.5, 0.5, 0.5]
                return DeviceCalendar(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source.title, color: rgb.prefix(3).map(Double.init))
            }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
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
