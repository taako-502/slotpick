import Foundation
import SlotPickCore
import XCTest

@testable import SlotPickSupport

@MainActor
private final class FakeCalendar: CalendarProviding {
    var busy: [BusySlot] = []
    var error: Error?
    var onAccess: (() -> Void)?
    var intervals: [DateInterval] = []
    var accessRequests = 0

    func requestAccess() async throws {
        accessRequests += 1
        onAccess?()
        if let error { throw error }
    }
    func busySlots(in interval: DateInterval) throws -> [BusySlot] {
        if let error { throw error }
        intervals.append(interval)
        return busy
    }
}

@MainActor
private final class FakeClipboard: ClipboardWriting {
    var value = "original clipboard"
    var succeed = true
    func write(_ text: String) -> Bool {
        if succeed { value = text }
        return succeed
    }
}

@MainActor
final class SlotPickModelTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }
    private func date(_ day: Int = 6, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testPermissionWaitUsesFreshTimeAndSearchDay() async {
        let service = FakeCalendar()
        let clipboard = FakeClipboard()
        var now = date(6, 23, 59)
        service.onAccess = { now = self.date(7, 10, 1) }
        let model = SlotPickModel(service: service, clipboard: clipboard, now: { now }, calendar: { self.calendar })
        await model.generate()
        XCTAssertEqual(model.candidates.first?.start, date(7, 10, 15))
        XCTAssertEqual(service.intervals.first?.start, date(6, 23, 30))
    }

    func testCopyMatchesPreviewAndRechecksCalendar() async {
        let service = FakeCalendar()
        let clipboard = FakeClipboard()
        let model = SlotPickModel(
            service: service, clipboard: clipboard, now: { self.date(6, 9) }, calendar: { self.calendar })
        await model.generate()
        model.copy()
        XCTAssertTrue(model.copied)
        XCTAssertEqual(clipboard.value, model.text)
        XCTAssertEqual(service.intervals.count, 2)
    }

    func testNewConflictingEventPreventsCopyWithoutNotification() async {
        let service = FakeCalendar()
        let clipboard = FakeClipboard()
        let model = SlotPickModel(
            service: service, clipboard: clipboard, now: { self.date(6, 9) }, calendar: { self.calendar })
        await model.generate()
        service.busy = [BusySlot(start: date(6, 10), end: date(6, 11))]
        model.copy()
        XCTAssertEqual(clipboard.value, "original clipboard")
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNotNil(model.message)
    }

    func testPastCandidatePreventsCopy() async {
        let service = FakeCalendar()
        let clipboard = FakeClipboard()
        var now = date(6, 9)
        let model = SlotPickModel(service: service, clipboard: clipboard, now: { now }, calendar: { self.calendar })
        await model.generate()
        now = date(6, 10, 1)
        model.copy()
        XCTAssertEqual(clipboard.value, "original clipboard")
        XCTAssertFalse(model.hasGenerated)
    }

    func testCalendarChangeClearsGeneratedText() async {
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { self.calendar })
        await model.generate()
        model.calendarDidChange()
        XCTAssertTrue(model.text.isEmpty)
        XCTAssertFalse(model.hasGenerated)
        XCTAssertNotNil(model.message)
    }

    func testConditionChangeClearsCandidates() async {
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { self.calendar })
        await model.generate()
        model.condition.durationMinutes = 30
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertTrue(model.text.isEmpty)
    }

    func testModeSwitchInvalidatesPreviewAndCopiesEntireRange() async {
        let clipboard = FakeClipboard()
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: clipboard, now: { self.date(6, 9) }, calendar: { self.calendar })
        XCTAssertEqual(model.condition.candidateMode, .freeTimeRanges)
        model.condition.candidateMode = .fixedDuration
        model.condition.searchDays = 1
        await model.generate()
        XCTAssertEqual(model.candidates.first?.end, date(6, 11))
        model.condition.candidateMode = .freeTimeRanges
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertTrue(model.text.isEmpty)
        XCTAssertFalse(model.hasGenerated)
        await model.generate()
        XCTAssertEqual(model.candidates, [CandidateSlot(start: date(6, 10), end: date(6, 18))])
        XCTAssertTrue(model.text.contains("10:00〜18:00"))
        model.copy()
        XCTAssertTrue(model.copied)
        XCTAssertEqual(clipboard.value, model.text)
        model.condition.candidateMode = .fixedDuration
        await model.generate()
        XCTAssertEqual(model.candidates.first?.end, date(6, 11))
    }

    func testNewEventInsideRangePreventsCopy() async {
        let service = FakeCalendar()
        let clipboard = FakeClipboard()
        let model = SlotPickModel(
            service: service, clipboard: clipboard, now: { self.date(6, 9) }, calendar: { self.calendar })
        model.condition.candidateMode = .freeTimeRanges
        await model.generate()
        service.busy = [BusySlot(start: date(6, 15), end: date(6, 16))]
        model.copy()
        XCTAssertEqual(clipboard.value, "original clipboard")
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertNotNil(model.message)
    }

    func testConditionChangeDuringPermissionWaitDiscardsResult() async {
        let service = FakeCalendar()
        let model = SlotPickModel(
            service: service, clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { self.calendar })
        service.onAccess = { model.condition.durationMinutes = 30 }
        await model.generate()
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(service.intervals.isEmpty)
    }

    func testRevokedPermissionPreventsCopy() async {
        let service = FakeCalendar()
        let clipboard = FakeClipboard()
        let model = SlotPickModel(
            service: service, clipboard: clipboard, now: { self.date(6, 9) }, calendar: { self.calendar })
        await model.generate()
        service.error = CalendarError.accessDenied
        model.copy()
        XCTAssertEqual(clipboard.value, "original clipboard")
        XCTAssertFalse(model.hasGenerated)
    }

    func testClipboardFailureIsVisible() async {
        let clipboard = FakeClipboard()
        clipboard.succeed = false
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: clipboard, now: { self.date(6, 9) }, calendar: { self.calendar })
        await model.generate()
        model.copy()
        XCTAssertFalse(model.copied)
        XCTAssertEqual(model.message, "コピーできませんでした。もう一度お試しください。")
    }

    func testTimeZoneChangeInvalidatesCandidates() async {
        var cal = calendar
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { cal })
        await model.generate()
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        model.checkFreshness()
        XCTAssertFalse(model.hasGenerated)
    }

    func testDeniedAccessShowsErrorAndEndsLoading() async {
        let service = FakeCalendar()
        service.error = CalendarError.accessDenied
        let model = SlotPickModel(service: service, clipboard: FakeClipboard())
        await model.generate()
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasGenerated)
        XCTAssertNotNil(model.message)
    }
    func testExclusionSettingsInvalidateGeneratedCandidates() async {
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { self.calendar })
        await model.generate()
        model.condition.excludeWeekends = true
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.hasGenerated)
        await model.generate()
        model.condition.excludeHolidays = true
        XCTAssertTrue(model.text.isEmpty)
        XCTAssertFalse(model.hasGenerated)
    }

    func testMissingHolidayDataShowsWarningBeforeCalendarAccess() async {
        let service = FakeCalendar()
        let unavailable = calendar.date(
            from: DateComponents(year: JapaneseHolidays.supportedYears.upperBound + 1, month: 1, day: 1, hour: 9))!
        let model = SlotPickModel(
            service: service, clipboard: FakeClipboard(), now: { unavailable }, calendar: { self.calendar })
        model.condition.excludeHolidays = true
        await model.generate()
        XCTAssertTrue(model.isHolidayDataWarning)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasGenerated)
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertEqual(service.accessRequests, 0)
        XCTAssertTrue(service.intervals.isEmpty)
        model.condition.excludeHolidays = false
        XCTAssertFalse(model.isHolidayDataWarning)
        XCTAssertNil(model.message)
        await model.generate()
        XCTAssertFalse(model.candidates.isEmpty)
    }

    func testDataCoverageWarningAfterPermissionWaitCrossesYear() async {
        let service = FakeCalendar()
        var timestamp = calendar.date(
            from: DateComponents(year: JapaneseHolidays.supportedYears.upperBound, month: 12, day: 31, hour: 23))!
        service.onAccess = { timestamp = timestamp.addingTimeInterval(7200) }
        let model = SlotPickModel(
            service: service, clipboard: FakeClipboard(), now: { timestamp }, calendar: { self.calendar })
        model.condition.searchDays = 1
        model.condition.excludeHolidays = true
        await model.generate()
        XCTAssertTrue(model.isHolidayDataWarning)
        XCTAssertTrue(service.intervals.isEmpty)
    }

    func testOrdinaryErrorsDoNotShowHolidayDataWarning() async {
        let service = FakeCalendar()
        service.error = CalendarError.accessDenied
        let model = SlotPickModel(
            service: service, clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { self.calendar })
        model.condition.excludeHolidays = true
        await model.generate()
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isHolidayDataWarning)
    }

}
