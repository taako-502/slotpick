import Foundation

public enum CandidateMode: Hashable, Sendable {
    case fixedDuration
    case freeTimeRanges
}

public struct SearchCondition: Equatable, Sendable {
    public var startDaysFromNow = 0
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
        guard (0...90).contains(startDaysFromNow),
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

    /// Validate data coverage before asking for calendar access or fetching personal events.
    public func validateHolidayCoverage(now: Date, calendar: Calendar) throws {
        try validate()
        guard excludeHolidays else { return }
        let firstDay = try searchStartDay(now: now, calendar: calendar)
        guard let lastDay = calendar.date(byAdding: .day, value: searchDays - 1, to: firstDay) else {
            throw GenerationError.invalidCondition
        }
        _ = try JapaneseHolidays.isHoliday(firstDay, timeZone: calendar.timeZone)
        _ = try JapaneseHolidays.isHoliday(lastDay, timeZone: calendar.timeZone)
    }

    /// Use calendar days so the selected date stays correct across daylight saving changes.
    public func searchStartDay(now: Date, calendar: Calendar) throws -> Date {
        try validate()
        guard
            let day = calendar.date(
                byAdding: .day, value: startDaysFromNow, to: calendar.startOfDay(for: now))
        else { throw GenerationError.invalidCondition }
        return day
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
