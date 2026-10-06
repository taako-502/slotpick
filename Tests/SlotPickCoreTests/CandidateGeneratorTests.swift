import XCTest

@testable import SlotPickCore

private func fixedDurationCondition() -> SearchCondition {
    var condition = SearchCondition()
    condition.candidateMode = .fixedDuration
    return condition
}

final class CandidateGeneratorTests: XCTestCase {
    var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return c
    }
    func date(_ day: Int = 6, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }
    func generate(_ busy: [BusySlot] = [], _ condition: SearchCondition = fixedDurationCondition(), now: Date? = nil)
        throws
        -> [CandidateSlot]
    {
        try CandidateGenerator().generate(
            busySlots: busy, condition: condition, now: now ?? date(6, 9), calendar: calendar)
    }
    func testSearchStartsThreeDaysLaterForBothModes() throws {
        for mode in [CandidateMode.fixedDuration, .freeTimeRanges] {
            var c = SearchCondition()
            c.startDaysFromNow = 3
            c.searchDays = 2
            c.candidateMode = mode
            let slots = try generate([], c)
            XCTAssertEqual(Set(slots.map { calendar.component(.day, from: $0.start) }), [9, 10])
            XCTAssertEqual(slots.first?.start, date(9, 10))
        }
    }

    func testOffsetQueryIncludesBuffersAroundWholeSelectedPeriod() throws {
        var c = SearchCondition()
        c.startDaysFromNow = 3
        c.searchDays = 2
        let interval = try c.eventQueryInterval(now: date(6, 9), calendar: calendar)
        XCTAssertEqual(interval.start, date(8, 23, 30))
        XCTAssertEqual(interval.end, date(11, 0, 30))
    }

    func testOffsetHolidayCoverageUsesSelectedDates() throws {
        var c = SearchCondition()
        c.startDaysFromNow = 2
        c.searchDays = 1
        c.excludeHolidays = true
        let now = calendar.date(from: DateComponents(year: 2027, month: 12, day: 30))!
        XCTAssertThrowsError(try c.validateHolidayCoverage(now: now, calendar: calendar))
    }

    func testInvalidStartOffsetIsRejected() {
        for offset in [-1, 91] {
            var c = SearchCondition()
            c.startDaysFromNow = offset
            XCTAssertThrowsError(try c.validate())
        }
    }

    func testFixedDurationSpreadsFiveCandidatesOverFiveDays() throws {
        let slots = try generate()
        XCTAssertEqual(slots.count, 5)
        XCTAssertEqual(slots.map { calendar.component(.day, from: $0.start) }, [6, 7, 8, 9, 10])
        XCTAssertTrue(slots.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
    }

    func testDefaultFreeTimeRangesKeepEntireEmptyWindow() throws {
        let c = SearchCondition()
        XCTAssertEqual(c.candidateMode, .freeTimeRanges)
        let slots = try generate([], c)
        XCTAssertEqual(slots, (6...10).map { CandidateSlot(start: date($0, 10), end: date($0, 18)) })
    }

    func testFreeTimeRangesRespectMergedEventsBuffersAndExactEnd() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.candidateMode = .freeTimeRanges
        let slots = try generate(
            [
                BusySlot(start: date(6, 13), end: date(6, 14)),
                BusySlot(start: date(6, 12, 37), end: date(6, 13, 30)),
            ], c)
        XCTAssertEqual(
            slots,
            [
                CandidateSlot(start: date(6, 10), end: date(6, 12, 7)),
                CandidateSlot(start: date(6, 14, 30), end: date(6, 18)),
            ])
    }

    func testFreeTimeRangesIncludeShortGapsRegardlessOfDuration() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.candidateMode = .freeTimeRanges
        c.bufferMinutes = 0
        c.maxCandidatesPerDay = 5
        let busy = [
            BusySlot(start: date(6, 11), end: date(6, 12, 7)),
            BusySlot(start: date(6, 13, 7), end: date(6, 17, 15)),
        ]
        let expected = [
            CandidateSlot(start: date(6, 10), end: date(6, 11)),
            CandidateSlot(start: date(6, 12, 15), end: date(6, 13, 7)),
            CandidateSlot(start: date(6, 17, 15), end: date(6, 18)),
        ]
        for minutes in [15, 60, 240] {
            c.durationMinutes = minutes
            XCTAssertEqual(try generate(busy, c), expected)
        }
    }

    func testFreeTimeRangesDoNotIncludeEmptyGapsAfterRounding() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.candidateMode = .freeTimeRanges
        c.bufferMinutes = 0
        XCTAssertEqual(
            try generate(
                [
                    BusySlot(start: date(6, 11), end: date(6, 12, 7)),
                    BusySlot(start: date(6, 12, 15), end: date(6, 17, 50)),
                ], c), [CandidateSlot(start: date(6, 10), end: date(6, 11))])
    }

    func testFreeTimeRangesRespectNowAndOvernightBuffers() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.candidateMode = .freeTimeRanges
        XCTAssertEqual(
            try generate([], c, now: date(6, 13, 7)),
            [
                CandidateSlot(start: date(6, 13, 15), end: date(6, 18))
            ])
        XCTAssertEqual(
            try generate([BusySlot(start: date(5, 23), end: date(6, 10, 7))], c),
            [
                CandidateSlot(start: date(6, 10, 45), end: date(6, 18))
            ])
        XCTAssertTrue(try generate([BusySlot(start: date(6, 0), end: date(7, 0))], c).isEmpty)
        XCTAssertTrue(try generate([], c, now: date(6, 18)).isEmpty)
    }

    func testFreeTimeRangesRespectDailyLimitAndSpreadAcrossDays() throws {
        var c = fixedDurationCondition()
        c.searchDays = 2
        c.candidateMode = .freeTimeRanges
        c.candidateCount = 3
        c.maxCandidatesPerDay = 2
        c.bufferMinutes = 0
        let busy = (6...7).flatMap { day in
            [
                BusySlot(start: date(day, 12), end: date(day, 13)),
                BusySlot(start: date(day, 15), end: date(day, 16)),
            ]
        }
        XCTAssertEqual(
            try generate(busy, c),
            [
                CandidateSlot(start: date(6, 10), end: date(6, 12)),
                CandidateSlot(start: date(6, 13), end: date(6, 15)),
                CandidateSlot(start: date(7, 10), end: date(7, 12)),
            ])
        c.candidateCount = 10
        XCTAssertEqual(try generate(busy, c).count, 4)
    }

    func testFreeTimeRangesRespectExcludedDatesAndMidnightEnd() throws {
        var c = fixedDurationCondition()
        c.searchDays = 4
        c.candidateMode = .freeTimeRanges
        c.excludeWeekends = true
        c.excludeHolidays = true
        c.endHour = 24
        XCTAssertEqual(
            try generate([], c, now: date(10, 9)),
            [
                CandidateSlot(start: date(13, 10), end: date(14, 0))
            ])
    }
    func testBufferAndMergedOverlappingEvents() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        let slots = try generate(
            [
                BusySlot(start: date(6, 10), end: date(6, 11)), BusySlot(start: date(6, 10, 45), end: date(6, 12)),
                BusySlot(start: date(6, 14), end: date(6, 15)),
            ], c)
        XCTAssertEqual(slots.map(\.start), [date(6, 12, 30), date(6, 15, 30)])
    }
    func testAllDayEventAndNoAvailability() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        XCTAssertTrue(try generate([BusySlot(start: date(6, 0), end: date(7, 0))], c).isEmpty)
    }
    func testDailyLimitAndSecondRound() throws {
        var c = fixedDurationCondition()
        c.searchDays = 2
        let slots = try generate([], c)
        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(slots.map(\.start), [date(6, 10), date(6, 11), date(7, 10), date(7, 11)])
    }
    func testNowRoundsUpAndDoesNotOfferPastSlots() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        XCTAssertEqual(try generate([], c, now: date(6, 10, 7)).first?.start, date(6, 10, 15))
    }
    func testExactGapBoundaryFits() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.maxCandidatesPerDay = 1
        XCTAssertEqual(try generate([BusySlot(start: date(6, 11, 30), end: date(6, 18))], c).first?.end, date(6, 11))
    }
    func testOutsideRangeEventBufferBlocksStart() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        XCTAssertEqual(
            try generate([BusySlot(start: date(6, 8), end: date(6, 9, 45))], c).first?.start, date(6, 10, 15))
    }
    func testEventEndRoundsToQuarterHour() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        XCTAssertEqual(
            try generate([BusySlot(start: date(6, 9), end: date(6, 10, 7))], c).first?.start, date(6, 10, 45))
    }
    func testInvalidConditionsThrow() {
        var c = fixedDurationCondition()
        c.startHour = 18
        XCTAssertThrowsError(try generate([], c))
        c = fixedDurationCondition()
        c.durationMinutes = 0
        XCTAssertThrowsError(try generate([], c))
    }
    func testFormatterIncludesTimeZoneAndEndTime() throws {
        let text = CandidateFormatter().text(try generate(), timeZone: calendar.timeZone)
        XCTAssertTrue(text.contains("Asia/Tokyo"))
        XCTAssertTrue(text.contains("10月6日（火）10:00〜11:00"))
        XCTAssertEqual(CandidateFormatter().text([]), "")
    }
    func testDSTUsesCalendarDays() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 9))!
        let slots = try CandidateGenerator().generate(
            busySlots: [], condition: fixedDurationCondition(), now: now, calendar: cal)
        XCTAssertEqual(slots.map { cal.component(.hour, from: $0.start) }, [10, 10, 10, 10, 10])
        XCTAssertEqual(slots[1].start.timeIntervalSince(slots[0].start), 25 * 3600)
    }
    func testNonQuarterHourDurationKeepsCandidateStartsOnGrid() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.durationMinutes = 20
        XCTAssertEqual(try generate([], c).map(\.start), [date(6, 10), date(6, 10, 30)])
    }

    func testMidnightEndIncludesFollowingDate() {
        let slot = CandidateSlot(start: date(6, 23), end: date(7, 0))
        XCTAssertEqual(
            CandidateFormatter().line(slot, timeZone: calendar.timeZone),
            "・2026年10月6日（火）23:00〜2026年10月7日（水）00:00")
    }

    func testEndHour24AndNoCandidatePastWindow() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.startHour = 23
        c.endHour = 24
        let slots = try generate([], c)
        XCTAssertEqual(slots, [CandidateSlot(start: date(6, 23), end: date(7, 0))])
    }

    func testQueryIncludesBuffersOnBothSidesAndCalendarDayAcrossDST() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        let query = try c.eventQueryInterval(now: date(6, 9), calendar: calendar)
        XCTAssertEqual(query.start, date(5, 23, 30))
        XCTAssertEqual(query.end, date(7, 0, 30))
    }

    func testSecondsRoundUp() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        XCTAssertEqual(try generate([], c, now: date(6, 10).addingTimeInterval(0.1)).first?.start, date(6, 10, 15))
    }

    func testDSTSpringForwardDoesNotSpillOutsideLocalWindow() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        let now = cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 0))!
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.startHour = 1
        c.endHour = 4
        c.bufferMinutes = 0
        let slots = try CandidateGenerator().generate(busySlots: [], condition: c, now: now, calendar: cal)
        XCTAssertEqual(slots.count, 2)
        XCTAssertEqual(slots.map { cal.component(.hour, from: $0.start) }, [1, 3])
        XCTAssertTrue(slots.allSatisfy { $0.end.timeIntervalSince($0.start) == 3600 })
        XCTAssertTrue(CandidateFormatter().line(slots[0], timeZone: cal.timeZone).contains("-05:00"))
        XCTAssertTrue(CandidateFormatter().line(slots[0], timeZone: cal.timeZone).contains("-04:00"))
    }

    func testGeneratedSlotsRespectBusyBuffersAndBoundsForManySchedules() throws {
        // Deterministic schedules exercise nested, touching, unsorted, and cross-day events.
        for seed in 0..<40 {
            var c = fixedDurationCondition()
            c.searchDays = 3
            c.candidateCount = 10
            c.bufferMinutes = (seed % 4) * 15
            c.durationMinutes = [20, 30, 60, 90][seed % 4]
            let busy = (0..<9).map { index in
                let start = date(6 + index % 3, 7).addingTimeInterval(Double((seed * 43 + index * 97) % 660) * 60)
                return BusySlot(start: start, end: start.addingTimeInterval(Double(20 + index * 11) * 60))
            }.reversed()
            let slots = try generate(Array(busy), c)
            XCTAssertLessThanOrEqual(slots.count, c.candidateCount)
            for slot in slots {
                XCTAssertGreaterThanOrEqual(slot.start, date(6, 9))
                XCTAssertEqual(calendar.component(.minute, from: slot.start) % 15, 0)
                XCTAssertEqual(slot.end.timeIntervalSince(slot.start), Double(c.durationMinutes) * 60)
                let day = calendar.component(.day, from: slot.start)
                XCTAssertGreaterThanOrEqual(slot.start, date(day, 10))
                XCTAssertLessThanOrEqual(slot.end, date(day, 18))
                for block in busy {
                    let margin = Double(c.bufferMinutes) * 60
                    XCTAssertTrue(
                        slot.end <= block.start.addingTimeInterval(-margin)
                            || slot.start >= block.end.addingTimeInterval(margin))
                }
            }
            for pair in zip(slots, slots.dropFirst()) { XCTAssertLessThanOrEqual(pair.0.end, pair.1.start) }
            let grouped = Dictionary(grouping: slots) { calendar.startOfDay(for: $0.start) }
            XCTAssertTrue(grouped.values.allSatisfy { $0.count <= c.maxCandidatesPerDay })
        }
    }

    func testWeekendAndHolidayExclusionCombinations() throws {
        // 2026-10-10 Saturday, 11 Sunday, 12 Sports Day, 13 Tuesday.
        for (weekends, holidays, expected) in [
            (false, false, [10, 11, 12, 13]),
            (true, false, [12, 13]),
            (false, true, [10, 11, 13]),
            (true, true, [13]),
        ] {
            var c = fixedDurationCondition()
            c.searchDays = 4
            c.candidateCount = 10
            c.maxCandidatesPerDay = 1
            c.excludeWeekends = weekends
            c.excludeHolidays = holidays
            let slots = try generate([], c, now: date(10, 9))
            XCTAssertEqual(slots.map { calendar.component(.day, from: $0.start) }, expected)
        }
    }

    func testExcludedDaysDoNotExtendSearchWindow() throws {
        var c = fixedDurationCondition()
        c.searchDays = 3
        c.excludeWeekends = true
        c.excludeHolidays = true
        XCTAssertTrue(try generate([], c, now: date(10, 9)).isEmpty)
    }

    func testSubstituteAndCitizensHolidaysAreExcluded() throws {
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.excludeHolidays = true
        for (month, day) in [(5, 6), (9, 22)] {
            let now = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9))!
            XCTAssertTrue(try generate([], c, now: now).isEmpty)
        }
    }

    func testYearBoundaryExcludesNewYear() throws {
        var c = fixedDurationCondition()
        c.searchDays = 2
        c.excludeHolidays = true
        let now = calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 9))!
        let slots = try generate([], c, now: now)
        XCTAssertEqual(slots.count, 2)
        XCTAssertTrue(slots.allSatisfy { calendar.component(.day, from: $0.start) == 31 })
    }

    func testHolidayDataCoverageFailsOnlyWhenHolidayExclusionEnabled() throws {
        var c = fixedDurationCondition()
        c.searchDays = 2
        c.excludeHolidays = true
        let now = calendar.date(from: DateComponents(year: 2027, month: 12, day: 31, hour: 9))!
        XCTAssertThrowsError(try generate([], c, now: now)) { error in
            guard case GenerationError.holidayDataUnavailable = error else { return XCTFail("Wrong error") }
        }
        c.excludeHolidays = false
        XCTAssertFalse(try generate([], c, now: now).isEmpty)
    }

    func testHolidayDetectionUsesSearchTimeZoneAndGregorianYear() throws {
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = calendar.timeZone
        var c = fixedDurationCondition()
        c.searchDays = 1
        c.excludeHolidays = true
        XCTAssertTrue(
            try CandidateGenerator().generate(busySlots: [], condition: c, now: date(12, 9), calendar: japanese).isEmpty
        )
        let instant = date(12, 0, 30)
        XCTAssertTrue(try JapaneseHolidays.isHoliday(instant, timeZone: calendar.timeZone))
        XCTAssertFalse(try JapaneseHolidays.isHoliday(instant, timeZone: TimeZone(identifier: "America/Los_Angeles")!))
    }

}
