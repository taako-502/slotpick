import EventKit
import Foundation
import XCTest
@testable import SlotPickSupport

@MainActor
private final class FakeEventStore: EventStoreAccess {
    var authorizationStatus: EKAuthorizationStatus = .fullAccess
    var requestCount = 0
    var grantsAccess = true
    var availableCalendars: [EKCalendar] = []
    var storedEvents: [CalendarEvent] = []

    func requestFullAccess() async throws -> Bool {
        requestCount += 1
        authorizationStatus = grantsAccess ? .fullAccess : .denied
        return grantsAccess
    }
    func calendars() -> [EKCalendar] { availableCalendars }
    func events(in interval: DateInterval, calendars: [EKCalendar]) -> [CalendarEvent] { storedEvents }
}

@MainActor
final class CalendarServiceTests: XCTestCase {
    private var interval: DateInterval { DateInterval(start:Date(timeIntervalSince1970:0),duration:86400) }

    func testWriteOnlyCanUpgradeToReadAccess() async throws {
        let store = FakeEventStore(); store.authorizationStatus = .writeOnly
        try await CalendarService(store:store).requestAccess()
        XCTAssertEqual(store.requestCount,1)
        XCTAssertEqual(store.authorizationStatus,.fullAccess)
    }

    func testFirstRequestAndDeniedRequest() async throws {
        let store = FakeEventStore(); store.authorizationStatus = .notDetermined
        try await CalendarService(store:store).requestAccess()
        XCTAssertEqual(store.requestCount,1)
        store.authorizationStatus = .notDetermined; store.grantsAccess = false
        do {
            try await CalendarService(store:store).requestAccess()
            XCTFail("Denied access must throw")
        } catch { XCTAssertTrue(error is CalendarError) }
    }

    func testExistingFullAccessDoesNotPrompt() async throws {
        let store = FakeEventStore()
        try await CalendarService(store:store).requestAccess()
        XCTAssertEqual(store.requestCount,0)
    }

    func testDeniedAndRestrictedDoNotReprompt() async {
        for status: EKAuthorizationStatus in [.denied,.restricted] {
            let store = FakeEventStore(); store.authorizationStatus = status
            do {
                try await CalendarService(store:store).requestAccess()
                XCTFail("Access must fail")
            } catch { XCTAssertTrue(error is CalendarError) }
            XCTAssertEqual(store.requestCount,0)
        }
    }

    func testNoCalendarsDoesNotMasqueradeAsFreeTime() {
        XCTAssertThrowsError(try CalendarService(store:FakeEventStore()).busySlots(in:interval))
    }

    func testAvailabilityFilteringIncludesAllDayAndUnspecifiedEvents() throws {
        let eventStore = EKEventStore()
        let store = FakeEventStore()
        store.availableCalendars = [EKCalendar(for:.event,eventStore:eventStore)]
        store.storedEvents = [
            CalendarEvent(start:interval.start,end:interval.end,availability:.free,status:.confirmed),
            CalendarEvent(start:interval.start,end:interval.end,availability:.busy,status:.confirmed),
            CalendarEvent(start:interval.start,end:interval.end,availability:.notSupported,status:.none),
            CalendarEvent(start:interval.start,end:interval.start,availability:.busy,status:.confirmed),
            CalendarEvent(start:interval.start,end:interval.end,availability:.busy,status:.canceled),
            CalendarEvent(start:nil,end:interval.end,availability:.busy,status:.confirmed)
        ]
        XCTAssertEqual(try CalendarService(store:store).busySlots(in:interval).count,2)
    }
}
