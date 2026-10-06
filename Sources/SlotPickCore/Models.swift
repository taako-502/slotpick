import Foundation

public enum CandidateMode: String, Codable, Hashable, Sendable {
    case fixedDuration
    case freeTimeRanges
}

public struct SearchCondition: Codable, Equatable, Sendable {
    public var startAfterDays = 1
    public var searchDays = 7
    public var startHour = 10
    public var startMinute = 0
    public var endHour = 18
    public var endMinute = 0
    public var durationMinutes = 60
    public var candidateMode: CandidateMode = .freeTimeRanges
    public var bufferMinutes = 30
    public var candidateCount = 5
    public var maxCandidatesPerDay = 2
    public var excludeWeekends = false
    public var excludeHolidays = false

    public init() {}

    public var startTimeMinutes: Int {
        get { startHour * 60 + startMinute }
        set {
            startHour = newValue / 60
            startMinute = newValue % 60
        }
    }

    public var endTimeMinutes: Int {
        get { endHour * 60 + endMinute }
        set {
            endHour = newValue / 60
            endMinute = newValue % 60
        }
    }

    private enum CodingKeys: String, CodingKey {
        case startAfterDays, searchDays, startHour, startMinute, endHour, endMinute, durationMinutes, candidateMode
        case bufferMinutes, candidateCount, maxCandidatesPerDay, excludeWeekends, excludeHolidays
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Older saved conditions predate the configurable start day.
        startAfterDays = try values.decodeIfPresent(Int.self, forKey: .startAfterDays) ?? 1
        searchDays = try values.decode(Int.self, forKey: .searchDays)
        startHour = try values.decode(Int.self, forKey: .startHour)
        startMinute = try values.decodeIfPresent(Int.self, forKey: .startMinute) ?? 0
        endHour = try values.decode(Int.self, forKey: .endHour)
        endMinute = try values.decodeIfPresent(Int.self, forKey: .endMinute) ?? 0
        durationMinutes = try values.decode(Int.self, forKey: .durationMinutes)
        candidateMode = try values.decode(CandidateMode.self, forKey: .candidateMode)
        bufferMinutes = try values.decode(Int.self, forKey: .bufferMinutes)
        candidateCount = try values.decode(Int.self, forKey: .candidateCount)
        maxCandidatesPerDay = try values.decode(Int.self, forKey: .maxCandidatesPerDay)
        excludeWeekends = try values.decode(Bool.self, forKey: .excludeWeekends)
        excludeHolidays = try values.decode(Bool.self, forKey: .excludeHolidays)
    }

    public func validate() throws {
        guard (0...365).contains(startAfterDays),
            (1...90).contains(searchDays),
            (0...23).contains(startHour),
            [0, 30].contains(startMinute),
            (0...24).contains(endHour),
            [0, 30].contains(endMinute),
            endHour < 24 || endMinute == 0,
            startTimeMinutes < endTimeMinutes,
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
