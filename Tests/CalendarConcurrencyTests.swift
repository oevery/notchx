import EventKit
import XCTest
@testable import NotchX

private actor GatedCalendarService: CalendarEventServing {
    struct Request {
        let start: Date
        let completion: CheckedContinuation<[CalendarEventSnapshot], Never>
    }
    var requests: [Int: Request] = [:]
    var count = 0
    var holdCatalog = false
    var catalog: CheckedContinuation<[CalendarDisplayOption], Never>?
    let calendarsValue: [CalendarDisplayOption]
    init(_ calendars: [CalendarDisplayOption]) { calendarsValue = calendars }
    func delayCatalog() { holdCatalog = true }
    func catalogIsWaiting() -> Bool { catalog != nil }
    func calendars() async -> [CalendarDisplayOption] {
        if holdCatalog { return await withCheckedContinuation { catalog = $0 } }
        return calendarsValue
    }
    func completeCatalog() {
        holdCatalog = false
        catalog?.resume(returning: calendarsValue)
        catalog = nil
    }
    func events(start: Date, end: Date) async -> [CalendarEventSnapshot] {
        await withCheckedContinuation {
            requests[count] = Request(start: start, completion: $0)
            count += 1
        }
    }
    func complete(_ index: Int, _ events: [CalendarEventSnapshot]) {
        requests.removeValue(forKey: index)?.completion.resume(returning: events)
    }
    @discardableResult
    func completeAll(_ events: [CalendarEventSnapshot] = []) -> Int {
        completeCatalog()
        let pending = requests.values
        requests.removeAll()
        for request in pending { request.completion.resume(returning: events) }
        return pending.count
    }
    func containsStart(_ date: Date) -> Bool { requests.values.contains { $0.start == date } }
}

@MainActor
final class CalendarConcurrencyTests: XCTestCase {
    private func calendar(_ id: String = "work", source: String = "Account", kind: CalendarKind = .calDAV) -> CalendarDisplayOption {
        CalendarDisplayOption(id: id, title: id, sourceID: "account", sourceTitle: source,
                              colorComponents: [1, 0, 0, 1], type: kind)
    }
    private func event(_ id: String, title: String = " Meeting ", date: Date = Date(timeIntervalSince1970: 1000),
                       location: String? = "Office", calendar: CalendarDisplayOption? = nil) -> CalendarEventSnapshot {
        CalendarEventSnapshot(eventIdentifier: id, title: title, startDate: date, endDate: date.addingTimeInterval(60),
                              isAllDay: false, location: location, notes: "https://meet.google.com/example",
                              calendar: calendar ?? self.calendar())
    }
    private func preferences() -> UserDefaults {
        let domain = "app.notchx.tests.calendar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        return defaults
    }
    private func eventually(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !(await condition()) {
            if ContinuousClock.now >= deadline { throw NSError(domain: "Calendar test timed out", code: 1) }
            await Task.yield()
        }
    }
    private func drainCallbacks() async {
        // Allow resumed service continuations to reach the real manager's stale-result guards.
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func testFiltersSelectionDuplicateIdentityAndSnapshotChanges() {
        let a = event("a"), duplicate = event("b", title: "meeting", location: nil)
        let other = event("c", location: "Home")
        let holiday = event("h", calendar: calendar("holiday", source: "Public Holidays"))
        let birthday = event("bday", calendar: calendar("birthday", kind: .birthday))
        let all = CalendarEventFilter(enabledCalendarIDs: nil, hideBirthdays: false, hideHolidays: false, collapseDuplicates: false)
        XCTAssertEqual(all.visibleEvents(from: [a, duplicate]).count, 2)
        let filtered = CalendarEventFilter(enabledCalendarIDs: nil, hideBirthdays: true, hideHolidays: true, collapseDuplicates: true)
        XCTAssertEqual(filtered.visibleEvents(from: [a, duplicate, other, holiday, birthday]), [a, other])
        XCTAssertTrue(CalendarEventFilter(enabledCalendarIDs: [], hideBirthdays: false, hideHolidays: false, collapseDuplicates: false).visibleEvents(from: [a]).isEmpty)
        XCTAssertEqual(CalendarEventFilter(enabledCalendarIDs: ["work"], hideBirthdays: false, hideHolidays: false, collapseDuplicates: false).visibleEvents(from: [a, holiday]), [a])
        XCTAssertNotEqual(a, event("a", location: "Changed"))
    }

    func testLatestDateWinsAndDisableAndRevocationRejectPendingQueries() async throws {
        let service = GatedCalendarService([calendar()])
        var access = EKAuthorizationStatus.fullAccess
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        let manager = CalendarManager(service: service, preferences: preferences(), authorization: { access },
                                      scheduler: scheduler, notifications: NotificationCenter())
        addTeardownBlock { @MainActor in manager.setEnabled(false); await service.completeAll() }
        manager.setEnabled(true)
        try await eventually { await service.count == 2 }
        manager.selectDate(Date(timeIntervalSince1970: 100000))
        try await eventually { await service.count == 3 }
        manager.selectDate(Date(timeIntervalSince1970: 200000))
        try await eventually { await service.count == 4 }
        let latest = event("latest")
        await service.complete(3, [latest])
        try await eventually { manager.selectedDateEvents == [latest] }
        await service.complete(2, [event("stale")])
        await drainCallbacks()
        XCTAssertEqual(manager.selectedDateEvents, [latest])
        XCTAssertEqual(manager.joinURL(for: latest)?.host, "meet.google.com")
        manager.setEnabled(false)
        let lateDate = Calendar.current.startOfDay(for: Date()).addingTimeInterval(3600)
        let disabledReplies = await service.completeAll([event("late-after-disable", date: lateDate)])
        XCTAssertEqual(disabledReplies, 2, "Both today and month requests must actually be resumed")
        await drainCallbacks()
        XCTAssertTrue(manager.todayEvents.isEmpty && manager.selectedDateEvents.isEmpty && manager.datesWithEvents.isEmpty)
        XCTAssertEqual(scheduler.jobCountForTesting, 0)
        manager.setEnabled(true)
        try await eventually { await service.count == 6 }
        access = .denied
        manager.refreshAccessStatus()
        let revokedReplies = await service.completeAll([event("late-after-revocation", date: lateDate)])
        XCTAssertEqual(revokedReplies, 2, "Revocation must be tested with outstanding nonempty responses")
        await drainCallbacks()
        XCTAssertFalse(manager.hasAccess)
        XCTAssertTrue(manager.todayEvents.isEmpty && manager.datesWithEvents.isEmpty)
        XCTAssertEqual(scheduler.jobCountForTesting, 0)
    }

    func testDelayedCatalogPreservesSelectionAndReminderOptInDoesNotReplay() async throws {
        let service = GatedCalendarService([calendar(), calendar("other")])
        await service.delayCatalog()
        let manager = CalendarManager(service: service, preferences: preferences(), authorization: { .fullAccess },
                                      scheduler: ModuleRefreshScheduler(isolatedForTesting: true), notifications: NotificationCenter())
        addTeardownBlock { @MainActor in manager.setEnabled(false); await service.completeAll() }
        var reminders = false, presented = 0
        manager.remindersEnabled = { reminders }
        manager.onReminderPresented = { presented += 1 }
        manager.setEnabled(true)
        try await eventually { await service.catalogIsWaiting() }
        manager.selectDate(Date(timeIntervalSince1970: 300000))
        manager.fetchTodayEvents()
        manager.prefetchDatesWithEventsIfNeeded()
        let earlyCount = await service.count
        XCTAssertEqual(earlyCount, 0)
        XCTAssertTrue(manager.todayEvents.isEmpty && manager.selectedDateEvents.isEmpty)
        await service.completeCatalog()
        try await eventually { await service.count == 2 }
        let a = event("a")
        await service.complete(0, [a])
        await service.complete(1, [a])
        try await eventually { manager.todayEvents == [a] }
        let selected = Calendar.current.startOfDay(for: manager.selectedDate)
        try await eventually { await service.containsStart(selected) }
        manager.hideCalendar(for: a)
        XCTAssertEqual(manager.enabledCalendarIDs, ["other"])
        let soon = event("soon", date: Date().addingTimeInterval(60))
        manager.todayEvents = [soon]
        manager.updateClock()
        manager.refreshReminderSchedule()
        XCTAssertNil(manager.reminderEvent)
        XCTAssertEqual(presented, 0)
        reminders = true
        manager.refreshReminderSchedule()
        XCTAssertEqual(manager.reminderEvent, soon)
        XCTAssertEqual(manager.featuredEvent, soon)
        XCTAssertEqual(presented, 1)
        reminders = false
        manager.refreshReminderSchedule()
        XCTAssertNil(manager.reminderEvent)
        reminders = true
        manager.refreshReminderSchedule()
        XCTAssertEqual(presented, 1)
        let later = event("later", date: Date().addingTimeInterval(120))
        manager.todayEvents = [later]
        manager.updateClock()
        manager.refreshReminderSchedule()
        XCTAssertEqual(manager.reminderEvent, later)
        manager.updateClock(now: later.startDate)
        XCTAssertNil(manager.reminderEvent)
        XCTAssertEqual(manager.featuredEvent, later)
    }
}
