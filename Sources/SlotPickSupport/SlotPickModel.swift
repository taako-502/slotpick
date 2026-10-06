import AppKit
import Foundation
import Observation
import SlotPickCore

@MainActor
public protocol ClipboardWriting {
    func write(_ text: String) -> Bool
}

@MainActor
public struct SystemClipboard: ClipboardWriting {
    public init() {}
    public func write(_ text: String) -> Bool {
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(text, forType: .string)
    }
}

@MainActor
@Observable
public final class SlotPickModel {
    public var condition = SearchCondition() {
        didSet {
            if condition != oldValue {
                if let data = try? JSONEncoder().encode(condition) {
                    preferences?.set(data, forKey: Self.conditionKey)
                }
                invalidate()
            }
        }
    }
    public private(set) var candidates: [CandidateSlot] = []
    public private(set) var text = ""
    public private(set) var message: String?
    public private(set) var isHolidayDataWarning = false
    public private(set) var isLoading = false
    public private(set) var hasGenerated = false
    public private(set) var copied = false

    @ObservationIgnored private let service: any CalendarProviding
    @ObservationIgnored private let clipboard: any ClipboardWriting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let currentCalendar: () -> Calendar
    @ObservationIgnored private let preferences: UserDefaults?
    static let conditionKey = "lastSearchCondition.v1"
    @ObservationIgnored private var generatedTimeZone: TimeZone?
    @ObservationIgnored private var revision = 0

    public init(
        service: any CalendarProviding,
        clipboard: any ClipboardWriting,
        now: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { Calendar.current },
        preferences: UserDefaults? = nil
    ) {
        self.service = service
        self.clipboard = clipboard
        self.now = now
        self.currentCalendar = calendar
        self.preferences = preferences
        if let data = preferences?.data(forKey: Self.conditionKey),
            let saved = try? JSONDecoder().decode(SearchCondition.self, from: data)
        {
            condition = saved
        }
    }

    public func generate() async {
        guard !isLoading else { return }
        invalidate()
        let requestedRevision = revision
        let snapshot = condition
        isLoading = true
        defer { isLoading = false }
        do {
            try snapshot.validateHolidayCoverage(now: now(), calendar: currentCalendar())
            try await service.requestAccess()
            guard requestedRevision == revision, !Task.isCancelled else { return }
            // Permission prompts can remain open for minutes or across midnight.
            let calendar = currentCalendar()
            let timestamp = now()
            candidates = try refreshedCandidates(condition: snapshot, now: timestamp, calendar: calendar)
            generatedTimeZone = calendar.timeZone
            text = CandidateFormatter().text(candidates, timeZone: calendar.timeZone)
            hasGenerated = true
        } catch {
            if requestedRevision == revision { show(error: error) }
        }
    }

    public func calendarDidChange() {
        // Changes during the permission prompt are covered by the subsequent fetch.
        if hasGenerated { invalidate(message: "カレンダーが更新されました。候補を再生成してください。") }
    }

    public func checkFreshness() {
        guard hasGenerated else { return }
        if generatedTimeZone != currentCalendar().timeZone || candidates.contains(where: { $0.start < now() }) {
            invalidate(message: "時刻またはタイムゾーンが変わりました。候補を再生成してください。")
        }
    }

    public func copy() {
        guard !isLoading, !candidates.isEmpty else { return }
        checkFreshness()
        guard !candidates.isEmpty else { return }
        do {
            // Fetch again even if EventKit's change notification has not arrived yet.
            let fresh = try refreshedCandidates(condition: condition, now: now(), calendar: currentCalendar())
            guard fresh == candidates else {
                invalidate(message: "空き時間が変わりました。候補を再生成してください。")
                return
            }
            copied = clipboard.write(text)
            message = copied ? nil : "コピーできませんでした。もう一度お試しください。"
        } catch {
            show(error: error)
        }
    }

    private func refreshedCandidates(condition: SearchCondition, now: Date, calendar: Calendar) throws
        -> [CandidateSlot]
    {
        try condition.validateHolidayCoverage(now: now, calendar: calendar)
        let interval = try condition.eventQueryInterval(now: now, calendar: calendar)
        let busy = try service.busySlots(in: interval)
        return try CandidateGenerator().generate(busySlots: busy, condition: condition, now: now, calendar: calendar)
    }

    private func show(error: Error) {
        invalidate(message: error.localizedDescription)
        if let generationError = error as? GenerationError,
            case .holidayDataUnavailable = generationError
        {
            isHolidayDataWarning = true
        }
    }

    private func invalidate(message: String? = nil) {
        revision += 1
        candidates = []
        text = ""
        hasGenerated = false
        copied = false
        generatedTimeZone = nil
        self.message = message
        isHolidayDataWarning = false
    }
}
