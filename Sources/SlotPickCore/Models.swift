import Foundation

public enum CandidateMode: Hashable, Sendable {
    case fixedDuration
    case freeTimeRanges
}

public struct SearchCondition: Equatable, Sendable {
    public var startAfterDays = 1
    public var searchDays = 7
    public var startHour = 10
    public var endHour = 18
    public var durationMinutes = 60
    public var candidateMode: CandidateMode = .freeTimeRanges
    public var bufferMinutes = 30
    public var candidateCount = 5
    public var maxCandidatesPerDay = 2
    public var excludeWeekends = false
    public var excludeHolidays = false

    public init() {}

    public func validate() throws {
        guard (0...365).contains(startAfterDays),
            (1...90).contains(searchDays),
            (0...23).contains(startHour),
            (1...24).contains(endHour),
            startHour < endHour,
            (1...240).contains(durationMinutes),
            (0...120).contains(bufferMinutes),
            (1...100).contains(candidateCount),
            (1...20).contains(maxCandidatesPerDay)
        else {
            throw GenerationError.invalidCondition
        }
    }

    /// Count eligible days after today; excluded dates do not advance the count.
    public func searchStartDay(now: Date, calendar: Calendar) throws -> Date {
        try validate()
        var day = calendar.startOfDay(for: now)
        var remaining = startAfterDays
        while remaining > 0 {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else {
                throw GenerationError.invalidCondition
            }
            day = next
            if try !isExcludedDay(day, calendar: calendar) { remaining -= 1 }
        }
        return day
    }

    public func isExcludedDay(_ day: Date, calendar: Calendar) throws -> Bool {
        // Validate holiday coverage even when the date is also a weekend.
        let holiday =
            excludeHolidays
            ? try JapaneseHolidays.isHoliday(day, timeZone: calendar.timeZone) : false
        let weekday = calendar.component(.weekday, from: day)
        return holiday || (excludeWeekends && (weekday == 1 || weekday == 7))
    }

    /// Validate both the offset and search window before requesting calendar access.
    public func validateHolidayCoverage(now: Date, calendar: Calendar) throws {
        let firstDay = try searchStartDay(now: now, calendar: calendar)
        guard excludeHolidays else { return }
        guard let lastDay = calendar.date(byAdding: .day, value: searchDays - 1, to: firstDay) else {
            throw GenerationError.invalidCondition
        }
        _ = try JapaneseHolidays.isHoliday(firstDay, timeZone: calendar.timeZone)
        _ = try JapaneseHolidays.isHoliday(lastDay, timeZone: calendar.timeZone)
    }

    /// Include neighbouring events whose buffers can overlap the search window.
    public func eventQueryInterval(now: Date, calendar: Calendar) throws -> DateInterval {
        try validate()
        let start = try searchStartDay(now: now, calendar: calendar)
        guard let end = calendar.date(byAdding: .day, value: searchDays, to: start) else {
            throw GenerationError.invalidCondition
        }
        let buffer = TimeInterval(bufferMinutes * 60)
        return DateInterval(start: start.addingTimeInterval(-buffer), end: end.addingTimeInterval(buffer))
    }
}

public struct BusySlot: Equatable, Sendable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}

public struct CandidateSlot: Identifiable, Equatable, Sendable {
    public var id: Date { start }
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }
}
