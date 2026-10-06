import XCTest

@testable import SlotPickCore

final class SearchStartDayTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    func date(_ day: Int, month: Int = 10, year: Int = 2026, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testDefaultStartsTomorrow() throws {
        let condition = SearchCondition()
        XCTAssertEqual(condition.startAfterDays, 1)
        let slots = try CandidateGenerator().generate(
            busySlots: [], condition: condition, now: date(6, hour: 12), calendar: calendar)
        XCTAssertEqual(slots.first?.start, date(7, hour: 10))
    }

    func testThreeDaysWithEveryExclusionCombination() throws {
        // October 12, 2026 is a Monday holiday.
        for (weekends, holidays, expected) in [
            (false, false, 12), (true, false, 14), (false, true, 13), (true, true, 15),
        ] {
            var condition = SearchCondition()
            condition.startAfterDays = 3
            condition.excludeWeekends = weekends
            condition.excludeHolidays = holidays
            XCTAssertEqual(
                try condition.searchStartDay(now: date(9, hour: 19), calendar: calendar), date(expected))
        }
    }

    func testSubstituteAndCitizensHolidaysAreSkipped() throws {
        var condition = SearchCondition()
        condition.excludeHolidays = true
        XCTAssertEqual(
            try condition.searchStartDay(now: date(5, month: 5), calendar: calendar), date(7, month: 5))
        XCTAssertEqual(
            try condition.searchStartDay(now: date(20, month: 9), calendar: calendar), date(24, month: 9))
    }

    func testQueryAndCandidatesUseSameShiftedWindow() throws {
        var condition = SearchCondition()
        condition.startAfterDays = 3
        condition.searchDays = 2
        condition.excludeWeekends = true
        condition.excludeHolidays = true
        let now = date(9, hour: 12)
        let interval = try condition.eventQueryInterval(now: now, calendar: calendar)
        XCTAssertEqual(interval.start, date(15).addingTimeInterval(-1800))
        XCTAssertEqual(interval.end, date(17).addingTimeInterval(1800))
        let slots = try CandidateGenerator().generate(
            busySlots: [BusySlot(start: date(15), end: date(16))],
            condition: condition, now: now, calendar: calendar)
        XCTAssertEqual(slots, [CandidateSlot(start: date(16, hour: 10), end: date(16, hour: 18))])
    }

    func testSearchPeriodRemainsCalendarDays() throws {
        var condition = SearchCondition()
        condition.searchDays = 3
        condition.excludeWeekends = true
        let slots = try CandidateGenerator().generate(
            busySlots: [], condition: condition, now: date(8), calendar: calendar)
        XCTAssertEqual(slots, [CandidateSlot(start: date(9, hour: 10), end: date(9, hour: 18))])
    }

    func testHolidayCoverageIncludesOffsetAndShiftedEnd() throws {
        var condition = SearchCondition()
        condition.excludeHolidays = true
        condition.searchDays = 1
        let lastYear = JapaneseHolidays.supportedYears.upperBound
        XCTAssertThrowsError(
            try condition.validateHolidayCoverage(
                now: date(31, month: 12, year: lastYear), calendar: calendar))
        condition.searchDays = 3
        XCTAssertThrowsError(
            try condition.validateHolidayCoverage(
                now: date(29, month: 12, year: lastYear), calendar: calendar))
        condition.excludeHolidays = false
        XCTAssertNoThrow(
            try condition.validateHolidayCoverage(
                now: date(31, month: 12, year: lastYear), calendar: calendar))
    }

    func testOffsetUsesLocalCalendarAcrossDSTAndYearBoundary() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let tomorrow = cal.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        let condition = SearchCondition()
        XCTAssertEqual(try condition.searchStartDay(now: today, calendar: cal), tomorrow)
        XCTAssertEqual(tomorrow.timeIntervalSince(today), 25 * 3600)
        XCTAssertEqual(
            try condition.searchStartDay(now: date(31, month: 12), calendar: calendar),
            date(1, month: 1, year: 2027))
    }

    func testOffsetValidationAndToday() throws {
        var condition = SearchCondition()
        condition.startAfterDays = 0
        XCTAssertEqual(try condition.searchStartDay(now: date(6, hour: 12), calendar: calendar), date(6))
        for invalid in [-1, 366, Int.max] {
            condition.startAfterDays = invalid
            XCTAssertThrowsError(try condition.searchStartDay(now: date(6), calendar: calendar))
        }
    }
}
