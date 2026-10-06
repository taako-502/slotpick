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
        didSet { if condition != oldValue { invalidate() } }
    }
    public private(set) var candidates: [CandidateSlot] = []
    public private(set) var text = ""
    public private(set) var message: String?
    public private(set) var isLoading = false
    public private(set) var hasGenerated = false
    public private(set) var copied = false

    @ObservationIgnored private let service: any CalendarProviding
    @ObservationIgnored private let clipboard: any ClipboardWriting
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let currentCalendar: () -> Calendar
    @ObservationIgnored private var generatedTimeZone: TimeZone?
    @ObservationIgnored private var revision = 0

    public init(
        service: any CalendarProviding,
        clipboard: any ClipboardWriting,
        now: @escaping () -> Date = { Date() },
        calendar: @escaping () -> Calendar = { Calendar.current }
    ) {
        self.service = service
        self.clipboard = clipboard
        self.now = now
        self.currentCalendar = calendar
    }

    public func generate() async {
        guard !isLoading else { return }
        invalidate()
        let requestedRevision = revision
        let snapshot = condition
        isLoading = true
        defer { isLoading = false }
        do {
            try snapshot.validate()
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
            if requestedRevision == revision { message = error.localizedDescription }
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
            invalidate(message: error.localizedDescription)
        }
    }

    private func refreshedCandidates(condition: SearchCondition, now: Date, calendar: Calendar) throws -> [CandidateSlot] {
        let interval = try condition.eventQueryInterval(now: now, calendar: calendar)
        let busy = try service.busySlots(in: interval)
        return try CandidateGenerator().generate(busySlots: busy, condition: condition, now: now, calendar: calendar)
    }

    private func invalidate(message: String? = nil) {
        revision += 1
        candidates = []
        text = ""
        hasGenerated = false
        copied = false
        generatedTimeZone = nil
        self.message = message
    }
}
