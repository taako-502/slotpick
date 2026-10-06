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

    func testOffsetChangesInvalidateAndFetchShiftedDates() async {
        let service = FakeCalendar()
        let model = SlotPickModel(
            service: service, clipboard: FakeClipboard(), now: { self.date(9, 9) }, calendar: { self.calendar })
        await model.generate()
        XCTAssertEqual(model.candidates.first?.start, date(10, 10))
        model.condition.startAfterDays = 3
        XCTAssertFalse(model.hasGenerated)
        XCTAssertTrue(model.candidates.isEmpty)
        model.condition.excludeWeekends = true
        model.condition.excludeHolidays = true
        await model.generate()
        XCTAssertEqual(model.candidates.first?.start, date(15, 10))
        XCTAssertEqual(service.intervals.last?.start, date(14, 23, 30))
    }

    func testOffsetPastHolidayCoverageFailsBeforeAccess() async {
        let service = FakeCalendar()
        let timestamp = calendar.date(
            from: DateComponents(year: JapaneseHolidays.supportedYears.upperBound, month: 12, day: 31))!
        let model = SlotPickModel(
            service: service, clipboard: FakeClipboard(), now: { timestamp }, calendar: { self.calendar })
        model.condition.searchDays = 1
        model.condition.excludeHolidays = true
        await model.generate()
        XCTAssertTrue(model.isHolidayDataWarning)
        XCTAssertEqual(service.accessRequests, 0)
        XCTAssertTrue(service.intervals.isEmpty)
    }

    func testLastInputIsRestoredWithoutGenerating() throws {
        let suite = "SlotPickTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), preferences: preferences)
        XCTAssertEqual(model.condition, SearchCondition())
        model.condition.startAfterDays = 3
        model.condition.searchDays = 14
        model.condition.startTimeMinutes = 9 * 60 + 30
        model.condition.endTimeMinutes = 21 * 60 + 30
        model.condition.candidateMode = .fixedDuration
        model.condition.durationMinutes = 90
        model.condition.bufferMinutes = 45
        model.condition.candidateCount = 12
        model.condition.maxCandidatesPerDay = 4
        model.condition.excludeWeekends = true
        model.condition.excludeHolidays = true

        let service = FakeCalendar()
        let restored = SlotPickModel(
            service: service, clipboard: FakeClipboard(),
            preferences: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restored.condition, model.condition)
        XCTAssertFalse(restored.hasGenerated)
        XCTAssertTrue(restored.candidates.isEmpty)
        XCTAssertTrue(restored.text.isEmpty)
        XCTAssertEqual(service.accessRequests, 0)

        restored.condition.candidateMode = .freeTimeRanges
        let reopened = SlotPickModel(
            service: service, clipboard: FakeClipboard(), preferences: preferences)
        XCTAssertEqual(reopened.condition, restored.condition)
        XCTAssertEqual(reopened.condition.durationMinutes, 90)
    }

    func testSavedConditionWithoutOffsetPreservesPreviousInputs() throws {
        let suite = "SlotPickTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var expected = SearchCondition()
        expected.searchDays = 21
        expected.startHour = 9
        expected.excludeWeekends = true
        expected.excludeHolidays = true
        let encoded = try JSONEncoder().encode(expected)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "startAfterDays")
        legacy.removeValue(forKey: "startMinute")
        legacy.removeValue(forKey: "endMinute")
        preferences.set(try JSONSerialization.data(withJSONObject: legacy), forKey: SlotPickModel.conditionKey)
        let restored = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), preferences: preferences)
        XCTAssertEqual(restored.condition, expected)
        XCTAssertEqual(restored.condition.startAfterDays, 1)
    }

    func testUnfinishedTimeRangeIsPreserved() throws {
        let suite = "SlotPickTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), preferences: preferences)
        // Preserve the last input even before the user adjusts the end time.
        model.condition.startHour = 20
        let restored = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), preferences: preferences)
        XCTAssertEqual(restored.condition, model.condition)
        XCTAssertThrowsError(try restored.condition.validate())
    }

    func testUnreadableSavedInputFallsBackToDefaultsAndCanBeReplaced() throws {
        let suite = "SlotPickTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        for payload in ["not JSON", "{}", "{\"candidateMode\":\"unknown\"}"] {
            preferences.set(Data(payload.utf8), forKey: SlotPickModel.conditionKey)
            let model = SlotPickModel(
                service: FakeCalendar(), clipboard: FakeClipboard(), preferences: preferences)
            XCTAssertEqual(model.condition, SearchCondition())
            model.condition.searchDays = 21
            let restored = SlotPickModel(
                service: FakeCalendar(), clipboard: FakeClipboard(), preferences: preferences)
            XCTAssertEqual(restored.condition.searchDays, 21)
        }
    }

    func testOffsetAppliesToFetchGenerationAndCopy() async {
        let service = FakeCalendar()
        let clipboard = FakeClipboard()
        service.busy = [BusySlot(start: date(9, 10), end: date(9, 12))]
        let model = SlotPickModel(
            service: service, clipboard: clipboard, now: { self.date(6, 9) }, calendar: { self.calendar })
        model.condition.startAfterDays = 3
        model.condition.searchDays = 1
        await model.generate()
        XCTAssertEqual(model.candidates.first?.start, date(9, 12, 30))
        XCTAssertEqual(service.intervals.first?.start, date(8, 23, 30))
        XCTAssertEqual(service.intervals.first?.end, date(10, 0, 30))
        model.copy()
        XCTAssertTrue(model.copied)
        XCTAssertEqual(service.intervals.count, 2)
        model.condition.startAfterDays = 4
        XCTAssertTrue(model.candidates.isEmpty)
        XCTAssertFalse(model.hasGenerated)
    }

    func testPermissionWaitUsesFreshTimeAndSearchDay() async {
        let service = FakeCalendar()
        let clipboard = FakeClipboard()
        var now = date(6, 23, 59)
        service.onAccess = { now = self.date(7, 10, 1) }
        let model = SlotPickModel(service: service, clipboard: clipboard, now: { now }, calendar: { self.calendar })
        model.condition.startAfterDays = 0
        await model.generate()
        XCTAssertEqual(model.candidates.first?.start, date(7, 10, 15))
        XCTAssertEqual(service.intervals.first?.start, date(6, 23, 30))
    }

    func testCopyMatchesPreviewAndRechecksCalendar() async {
        let service = FakeCalendar()
        let clipboard = FakeClipboard()
        let model = SlotPickModel(
            service: service, clipboard: clipboard, now: { self.date(6, 9) }, calendar: { self.calendar })
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
        await model.generate()
        now = date(6, 10, 1)
        model.copy()
        XCTAssertEqual(clipboard.value, "original clipboard")
        XCTAssertFalse(model.hasGenerated)
    }

    func testCalendarChangeClearsGeneratedText() async {
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { self.calendar })
        model.condition.startAfterDays = 0
        await model.generate()
        model.calendarDidChange()
        XCTAssertTrue(model.text.isEmpty)
        XCTAssertFalse(model.hasGenerated)
        XCTAssertNotNil(model.message)
    }

    func testConditionChangeClearsCandidates() async {
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { self.calendar })
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
        await model.generate()
        model.copy()
        XCTAssertFalse(model.copied)
        XCTAssertEqual(model.message, "コピーできませんでした。もう一度お試しください。")
    }

    func testTimeZoneChangeInvalidatesCandidates() async {
        var cal = calendar
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { cal })
        model.condition.startAfterDays = 0
        await model.generate()
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        model.checkFreshness()
        XCTAssertFalse(model.hasGenerated)
    }

    func testDeniedAccessShowsErrorAndEndsLoading() async {
        let service = FakeCalendar()
        service.error = CalendarError.accessDenied
        let model = SlotPickModel(service: service, clipboard: FakeClipboard())
        model.condition.startAfterDays = 0
        await model.generate()
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasGenerated)
        XCTAssertNotNil(model.message)
    }
    func testExclusionSettingsInvalidateGeneratedCandidates() async {
        let model = SlotPickModel(
            service: FakeCalendar(), clipboard: FakeClipboard(), now: { self.date(6, 9) }, calendar: { self.calendar })
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
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
        model.condition.startAfterDays = 0
        await model.generate()
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isHolidayDataWarning)
    }

}
