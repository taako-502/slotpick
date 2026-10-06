import Foundation

public struct SearchCondition: Equatable, Sendable {
    public var searchDays = 7
    public var startHour = 10
    public var endHour = 18
    public var durationMinutes = 60
    public var bufferMinutes = 30
    public var candidateCount = 5
    public var maxCandidatesPerDay = 2

    public init() {}

    public func validate() throws {
        guard (1...90).contains(searchDays),
              (0...23).contains(startHour),
              (1...24).contains(endHour),
              startHour < endHour,
              (1...240).contains(durationMinutes),
              (0...120).contains(bufferMinutes),
              (1...100).contains(candidateCount),
              (1...20).contains(maxCandidatesPerDay) else {
            throw GenerationError.invalidCondition
        }
    }

    /// Include neighbouring events whose buffers can overlap the search window.
    public func eventQueryInterval(now: Date, calendar: Calendar) throws -> DateInterval {
        try validate()
        let start = calendar.startOfDay(for: now)
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
