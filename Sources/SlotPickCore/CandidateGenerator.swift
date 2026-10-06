import Foundation

public enum GenerationError: LocalizedError {
    case invalidCondition
    case holidayDataUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidCondition:
            "開始までの日数（0〜365日）、時間帯や候補数を確認してください。開始時刻は終了時刻より前にしてください。"
        case .holidayDataUnavailable:
            "祝日データの対応期間（\(JapaneseHolidays.supportedYears.lowerBound)〜\(JapaneseHolidays.supportedYears.upperBound)年）を超えています。アプリを更新するか、祝日の除外をオフにしてください。"
        }
    }
}

public struct CandidateGenerator {
    public init() {}

    public func generate(
        busySlots: [BusySlot],
        condition: SearchCondition,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> [CandidateSlot] {
        try condition.validateHolidayCoverage(now: now, calendar: calendar)
        let firstDay = try condition.searchStartDay(now: now, calendar: calendar)
        let busy = mergedBusySlots(busySlots, bufferMinutes: condition.bufferMinutes)
        let duration = TimeInterval(condition.durationMinutes * 60)
        var candidatesByDay: [[CandidateSlot]] = []

        for offset in 0..<condition.searchDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay),
                let nextDay = calendar.date(byAdding: .day, value: 1, to: day),
                let start = calendar.date(bySettingHour: condition.startHour, minute: condition.startMinute, second: 0, of: day),
                let end = condition.endHour == 24
                    ? nextDay
                    : calendar.date(
                        bySettingHour: condition.endHour, minute: condition.endMinute, second: 0, of: day
                    ), start < end, start < nextDay
            else { continue }

            if try condition.isExcludedDay(day, calendar: calendar) { continue }

            var cursor = max(start, now)
            var slots: [CandidateSlot] = []
            func appendGap(until limit: Date) {
                if condition.candidateMode == .freeTimeRanges {
                    guard slots.count < condition.maxCandidatesPerDay,
                        let rounded = roundedUp(cursor, calendar: calendar),
                        rounded < limit
                    else { return }
                    slots.append(CandidateSlot(start: rounded, end: limit))
                    cursor = limit
                    return
                }
                // Round every candidate, including non-quarter-hour durations.
                while slots.count < condition.maxCandidatesPerDay,
                    let rounded = roundedUp(cursor, calendar: calendar),
                    rounded.addingTimeInterval(duration) <= limit
                {
                    let finish = rounded.addingTimeInterval(duration)
                    slots.append(CandidateSlot(start: rounded, end: finish))
                    cursor = finish
                }
            }

            // Intervals are half-open: touching the buffer boundary is permitted.
            for block in busy where block.end > cursor && block.start < end {
                appendGap(until: min(block.start, end))
                cursor = max(cursor, block.end)
            }
            appendGap(until: end)
            candidatesByDay.append(slots)
        }

        // Fill earlier days up to the daily limit before offering later dates.
        var result: [CandidateSlot] = []
        for slots in candidatesByDay {
            for slot in slots {
                result.append(slot)
                if result.count == condition.candidateCount {
                    return result.sorted { $0.start < $1.start }
                }
            }
        }
        return result.sorted { $0.start < $1.start }
    }

    private func mergedBusySlots(_ slots: [BusySlot], bufferMinutes: Int) -> [BusySlot] {
        let buffer = TimeInterval(bufferMinutes * 60)
        let sorted = slots.filter { $0.start < $0.end }.map {
            BusySlot(start: $0.start.addingTimeInterval(-buffer), end: $0.end.addingTimeInterval(buffer))
        }.sorted { $0.start < $1.start }
        var merged: [BusySlot] = []
        for slot in sorted {
            if let last = merged.last, slot.start <= last.end {
                merged[merged.count - 1] = BusySlot(start: last.start, end: max(last.end, slot.end))
            } else {
                merged.append(slot)
            }
        }
        return merged
    }

    private func roundedUp(_ date: Date, calendar: Calendar) -> Date? {
        guard let minuteStart = calendar.dateInterval(of: .minute, for: date)?.start else { return nil }
        let minute = calendar.component(.minute, from: date)
        if minute % 15 == 0 && date == minuteStart { return date }
        return calendar.date(byAdding: .minute, value: 15 - minute % 15, to: minuteStart)
    }
}
