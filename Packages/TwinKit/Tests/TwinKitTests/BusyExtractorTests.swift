import Foundation
@testable import TwinAvailability
import TwinModels
import XCTest

final class BusyExtractorTests: XCTestCase {
    func testBusyBlocksFilterClipAndMergeWithoutEventDetails() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let hour: TimeInterval = 3_600
        let spans = [
            CalendarSpan(
                start: start.addingTimeInterval(-hour),
                end: start.addingTimeInterval(hour),
                availability: .busy,
                calendarID: "work"
            ),
            CalendarSpan(
                start: start.addingTimeInterval(hour),
                end: start.addingTimeInterval(2 * hour),
                availability: .tentative,
                calendarID: "work"
            ),
            CalendarSpan(
                start: start.addingTimeInterval(3 * hour),
                end: start.addingTimeInterval(4 * hour),
                availability: .free,
                calendarID: "work"
            ),
            CalendarSpan(
                start: start,
                end: start.addingTimeInterval(5 * hour),
                availability: .busy,
                calendarID: "hidden"
            ),
        ]

        let blocks = BusyExtractor.busyBlocks(
            from: spans,
            disabledCalendarIDs: ["hidden"],
            startingAt: start,
            horizon: 4 * hour
        )

        XCTAssertEqual(blocks, [BusyBlock(start: start, end: start.addingTimeInterval(2 * hour))])
    }

    func testAllDayTentativeAndUnsupportedEventsAreNotBusy() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        let end = start.addingTimeInterval(3_600)
        let spans = [
            CalendarSpan(
                start: start,
                end: end,
                availability: .tentative,
                calendarID: "calendar",
                isAllDay: true
            ),
            CalendarSpan(
                start: start,
                end: end,
                availability: .unsupported,
                calendarID: "calendar",
                isAllDay: true
            ),
        ]

        XCTAssertTrue(BusyExtractor.busyBlocks(from: spans, startingAt: start).isEmpty)
    }
}
