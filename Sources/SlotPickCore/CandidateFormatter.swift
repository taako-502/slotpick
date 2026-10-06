import Foundation

public struct CandidateFormatter {
    public init() {}

    public func line(_ slot: CandidateSlot, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = makeFormatter("yyyy年M月d日（E）HH:mm", timeZone: timeZone)
        let endFormat = calendar.isDate(slot.start, inSameDayAs: slot.end)
            ? "HH:mm" : "yyyy年M月d日（E）HH:mm"
        let end = makeFormatter(endFormat, timeZone: timeZone)
        // Distinguish repeated local times during the autumn DST transition.
        let startOffset = timeZone.secondsFromGMT(for: slot.start)
        let endOffset = timeZone.secondsFromGMT(for: slot.end)
        if startOffset != endOffset {
            let zoned = makeFormatter("yyyy年M月d日（E）HH:mm xxx", timeZone: timeZone)
            return "・\(zoned.string(from: slot.start))〜\(zoned.string(from: slot.end))"
        }
        return "・\(date.string(from: slot.start))〜\(end.string(from: slot.end))"
    }

    public func text(_ slots: [CandidateSlot], timeZone: TimeZone = .current) -> String {
        guard !slots.isEmpty else { return "" }
        let lines = slots.map { line($0, timeZone: timeZone) }.joined(separator: "\n")
        return "面談の候補日時をお送りします。\n（タイムゾーン：\(timeZone.identifier)）\n\n"
            + lines + "\n\nご都合のよい日時をお知らせいただけますと幸いです。"
    }

    private func makeFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
