import EventKit
import Foundation
import SlotPickCore

@MainActor
public protocol CalendarProviding {
    func requestAccess() async throws
    func busySlots(in interval: DateInterval) throws -> [BusySlot]
}

public enum CalendarError: LocalizedError {
    case accessDenied
    case restricted
    case noCalendars

    public var errorDescription: String? {
        switch self {
        case .accessDenied:
            "カレンダーの読み取り権限が必要です。システム設定 → プライバシーとセキュリティ → カレンダーでSlotPickのフルアクセスを許可してください。"
        case .restricted:
            "このMacではカレンダーへのアクセスが制限されています。管理者またはシステム設定を確認してください。"
        case .noCalendars:
            "読み取れるカレンダーがありません。Macの「カレンダー」アプリでアカウントと同期を確認してください。"
        }
    }
}

struct CalendarEvent {
    let start: Date?
    let end: Date?
    let availability: EKEventAvailability
    let status: EKEventStatus
}

/// A narrow adapter makes authorization and event filtering testable without accessing personal calendars.
@MainActor
protocol EventStoreAccess {
    var authorizationStatus: EKAuthorizationStatus { get }
    func requestFullAccess() async throws -> Bool
    func calendars() -> [EKCalendar]
    func events(in interval: DateInterval, calendars: [EKCalendar]) -> [CalendarEvent]
}

@MainActor
private final class SystemEventStore: EventStoreAccess {
    private let store = EKEventStore()

    var authorizationStatus: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }

    func requestFullAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    func calendars() -> [EKCalendar] { store.calendars(for: .event) }

    func events(in interval: DateInterval, calendars: [EKCalendar]) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: calendars)
        return store.events(matching: predicate).map {
            CalendarEvent(start: $0.startDate, end: $0.endDate, availability: $0.availability, status: $0.status)
        }
    }
}

@MainActor
public final class CalendarService: CalendarProviding {
    private let store: any EventStoreAccess

    public convenience init() { self.init(store: SystemEventStore()) }

    init(store: any EventStoreAccess) { self.store = store }

    public func requestAccess() async throws {
        switch store.authorizationStatus {
        case .fullAccess:
            return
        case .notDetermined, .writeOnly:
            guard try await store.requestFullAccess() else { throw CalendarError.accessDenied }
        case .restricted:
            throw CalendarError.restricted
        case .denied:
            throw CalendarError.accessDenied
        @unknown default:
            throw CalendarError.accessDenied
        }
        guard store.authorizationStatus == .fullAccess else { throw CalendarError.accessDenied }
    }

    public func busySlots(in interval: DateInterval) throws -> [BusySlot] {
        // Recheck access even after generation, because permissions can be revoked.
        guard store.authorizationStatus == .fullAccess else { throw CalendarError.accessDenied }
        let calendars = store.calendars()
        guard !calendars.isEmpty else { throw CalendarError.noCalendars }
        return store.events(in: interval, calendars: calendars).compactMap { event in
            guard event.availability != .free, event.status != .canceled,
                let start = event.start, let end = event.end, end > start
            else { return nil }
            return BusySlot(start: start, end: end)
        }
    }
}
