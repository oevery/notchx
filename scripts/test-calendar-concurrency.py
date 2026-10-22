#!/usr/bin/env python3
"""Execute production Calendar filtering and manager races with a gated service double.

This validates Swift control flow, not EventKit/Combine/CoreGraphics SDK integration.
The actual app still needs the macOS build and native tests.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
# Compile the production Calendar defaults too; do not duplicate reset defaults in doubles.
settings = (ROOT / 'App/Settings/SettingsRestore.swift').read_text()
setting_default = settings[settings.index('struct SettingDefault<Value: Sendable>'):settings.index('enum SettingsDefaults')]
restore_entry = settings[settings.index('struct SettingsRestoreEntry'):settings.index('enum SettingsRestoreScope')]
calendar_defaults = settings[settings.index('    enum Calendar {'):settings.index('    enum Weather {')]
production_defaults = setting_default + restore_entry + 'enum SettingsDefaults {\n' + calendar_defaults + '}\n'
models = (ROOT / 'App/Modules/Calendar/CalendarSnapshots.swift').read_text()
manager = (ROOT / 'App/Modules/Calendar/CalendarManager.swift').read_text()
manager = manager[manager.index('@MainActor\nfinal class CalendarManager'):]
manager = manager.replace('private init()', 'init()').replace('@objc ', '')
# Notification selectors require the Objective-C runtime; keep all fetch/lifecycle logic.
a = manager.index('    private func observeStoreChanges()')
b = manager.index('    private func stopRefresh()', a)
manager = manager[:a] + '    private func observeStoreChanges() {}\n\n' + manager[b:]
manager = manager.replace('        NotificationCenter.default.removeObserver(self, name: .NSCalendarDayChanged, object: nil)\n', '')
manager = manager.replace('        NotificationCenter.default.removeObserver(self, name: .EKEventStoreChanged, object: nil)\n', '')
stubs = r'''
import Foundation
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
private extension Int { var nonZero: Int? { self == 0 ? nil : self } }
enum EKAuthorizationStatus { case fullAccess, denied }
enum EKEntityType { case event }
@MainActor enum EKEventStore {
    static var status: EKAuthorizationStatus = .fullAccess
    static func authorizationStatus(for entity: EKEntityType) -> EKAuthorizationStatus { status }
}
@MainActor final class PermissionsManager {
    static let shared = PermissionsManager()
    func openCalendarSettings() {}
}
@MainActor final class PermissionState {
    static let shared = PermissionState()
    enum Permission { case calendar }
    func request(_ permission: Permission) async {}
}
enum L10n {
    static func text(_ s: String) -> String { s }
    static func format(_ s: String, _ n: Int...) -> String { String(format: s, arguments: n) }
}
enum ModuleType { case calendar }
enum ActiveModule { case builtIn(ModuleType) }
struct ModuleRefreshToken: Sendable {}
enum RefreshPolicy { case interval(Double, tolerance: Double), visibleOnly(Double, tolerance: Double) }
@MainActor final class ModuleRefreshScheduler {
    static let shared = ModuleRefreshScheduler()
    func register(id: String, name: String, module: ActiveModule, policy: RefreshPolicy, enabled: () -> Bool, action: () -> Void) -> ModuleRefreshToken { ModuleRefreshToken() }
    func unregister(_ token: ModuleRefreshToken?) {}
}
@MainActor final class AppState {
    static let shared = AppState()
    var calendarEnabled = true
    enum Event { case calendarReminder }
    struct Rule { var enabled = true }
    struct Preferences {
        var reminder = Rule()
        subscript(_ event: Event) -> Rule {
            get { reminder }
            set { reminder = newValue }
        }
    }
    enum State { case compact, expanded }
    var presentationPreferences = Preferences()
    var currentState = State.compact
    var activeBuiltInModule: ModuleType?
    var presentedCount = 0
    func presentEvent(_ event: Event) { presentedCount += 1 }
    func clearPendingEvents(for module: ModuleType) {}
    func dismiss() {}
    func showHUD(module: ModuleType, autoDismiss: Bool) {}
}
private actor CalendarEventService {
    static let shared = CalendarEventService()
    struct Request { let start: Date; let continuation: CheckedContinuation<[CalendarEventSnapshot], Never> }
    private var requests: [Request] = []
    func requestAccess() async throws -> Bool { true }
    private var holdCatalog = false
    private var catalogContinuation: CheckedContinuation<[CalendarDisplayOption], Never>?
    func delayCatalog() { holdCatalog = true }
    func catalogIsWaiting() -> Bool { catalogContinuation != nil }
    func completeCatalog() {
        holdCatalog = false
        catalogContinuation?.resume(returning: [calendar(), calendar("other")])
        catalogContinuation = nil
    }
    func calendars() async -> [CalendarDisplayOption] {
        if holdCatalog {
            return await withCheckedContinuation { catalogContinuation = $0 }
        }
        return [calendar(), calendar("other")]
    }
    func events(start: Date, end: Date) async -> [CalendarEventSnapshot] {
        await withCheckedContinuation { requests.append(Request(start: start, continuation: $0)) }
    }
    func count() -> Int { requests.count }
    func containsStart(_ start: Date) -> Bool { requests.contains { $0.start == start } }
    func complete(_ index: Int, _ events: [CalendarEventSnapshot]) { requests[index].continuation.resume(returning: events) }
    func completeAll(after index: Int) {
        for request in requests.dropFirst(index) { request.continuation.resume(returning: []) }
    }
}
'''
# Use the same service instance so the harness can release requests out of order.
manager = manager.replace('private let service = CalendarEventService()', 'private let service = CalendarEventService.shared')
checks = r'''
func calendar(_ id: String = "work", title: String = "Work", source: String = "Account", kind: CalendarKind = .calDAV) -> CalendarDisplayOption {
    CalendarDisplayOption(id: id, title: title, sourceID: "account", sourceTitle: source, colorComponents: [1, 0, 0, 1], type: kind)
}
func event(_ id: String, title: String = " Meeting ", date: Date = Date(timeIntervalSince1970: 1000), location: String? = "Office", calendar: CalendarDisplayOption = calendar()) -> CalendarEventSnapshot {
    CalendarEventSnapshot(eventIdentifier: id, title: title, startDate: date, endDate: date.addingTimeInterval(60), isAllDay: false, location: location, notes: "https://meet.google.com/example", calendar: calendar)
}
@main struct CalendarChecks {
    @MainActor static func waitUntil(_ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            precondition(Date() < deadline, "Timed out awaiting calendar task")
            await Task.yield()
        }
    }
    @MainActor static func main() async {
        let all = CalendarEventFilter(enabledCalendarIDs: nil, hideBirthdays: false, hideHolidays: false, collapseDuplicates: false)
        let a = event("a")
        let duplicate = event("b", title: "meeting", location: nil)
        let otherLocation = event("c", location: "Home")
        let holiday = event("holiday", calendar: calendar("holiday", source: "Public Holidays"))
        let birthday = event("birthday", calendar: calendar("birthday", kind: .birthday))
        precondition(all.visibleEvents(from: [a, duplicate]).count == 2)
        let collapsed = CalendarEventFilter(enabledCalendarIDs: nil, hideBirthdays: true, hideHolidays: true, collapseDuplicates: true)
        precondition(collapsed.visibleEvents(from: [a, duplicate, otherLocation, holiday, birthday]) == [a, otherLocation])
        precondition(CalendarEventFilter(enabledCalendarIDs: [], hideBirthdays: false, hideHolidays: false, collapseDuplicates: false).visibleEvents(from: [a]).isEmpty)
        precondition(CalendarEventFilter(enabledCalendarIDs: ["work"], hideBirthdays: false, hideHolidays: false, collapseDuplicates: false).visibleEvents(from: [a, holiday]) == [a])
        precondition(a != event("a", location: "Changed"), "Location edits must republish")
        let manager = CalendarManager()
        manager.setEnabled(true)
        await waitUntil { await CalendarEventService.shared.count() == 2 } // today and month
        manager.selectDate(Date(timeIntervalSince1970: 100000))
        await waitUntil { await CalendarEventService.shared.count() == 3 }
        manager.selectDate(Date(timeIntervalSince1970: 200000))
        await waitUntil { await CalendarEventService.shared.count() == 4 }
        await CalendarEventService.shared.complete(3, [otherLocation])
        await waitUntil { manager.selectedDateEvents == [otherLocation] }
        await CalendarEventService.shared.complete(2, [a])
        for _ in 0..<100 { await Task.yield() }
        precondition(manager.selectedDateEvents == [otherLocation], "Older selected-date request overwrote latest")
        precondition(manager.joinURL(for: a)?.host == "meet.google.com")
        manager.setEnabled(false)
        await CalendarEventService.shared.complete(0, [a])
        await CalendarEventService.shared.complete(1, [a])
        for _ in 0..<100 { await Task.yield() }
        precondition(manager.todayEvents.isEmpty && manager.selectedDateEvents.isEmpty && manager.datesWithEvents.isEmpty)
        manager.setEnabled(true)
        await waitUntil { await CalendarEventService.shared.count() == 6 }
        EKEventStore.status = .denied
        manager.refreshAccessStatus()
        await CalendarEventService.shared.completeAll(after: 4)
        for _ in 0..<100 { await Task.yield() }
        precondition(!manager.hasAccess && manager.todayEvents.isEmpty && manager.datesWithEvents.isEmpty)
        manager.setEnabled(false)
        // A delayed initial catalog must not expose Hide Calendar with an empty whitelist.
        EKEventStore.status = .fullAccess
        await CalendarEventService.shared.delayCatalog()
        let delayed = CalendarManager()
        delayed.remindersEnabled = { AppState.shared.presentationPreferences[.calendarReminder].enabled }
        delayed.onReminderPresented = { AppState.shared.presentEvent(.calendarReminder) }
        delayed.setEnabled(true)
        await waitUntil { await CalendarEventService.shared.catalogIsWaiting() }
        delayed.selectDate(Date(timeIntervalSince1970: 300000))
        delayed.fetchTodayEvents()
        delayed.prefetchDatesWithEventsIfNeeded()
        for _ in 0..<100 { await Task.yield() }
        let earlyRequestCount = await CalendarEventService.shared.count()
        precondition(earlyRequestCount == 6, "Events queried before catalog was loaded")
        precondition(delayed.todayEvents.isEmpty && delayed.selectedDateEvents.isEmpty)
        await CalendarEventService.shared.completeCatalog()
        await waitUntil { await CalendarEventService.shared.count() == 8 }
        // Today and month may be scheduled in either order; publish the same event to both.
        await CalendarEventService.shared.complete(6, [a])
        await CalendarEventService.shared.complete(7, [a])
        await waitUntil { delayed.todayEvents == [a] }
        let selectedDay = Calendar.current.startOfDay(for: delayed.selectedDate)
        await waitUntil { await CalendarEventService.shared.containsStart(selectedDay) }
        delayed.hideCalendar(for: a)
        precondition(delayed.enabledCalendarIDs == ["other"], "Hide Calendar disabled unrelated calendars")
        let soon = event("soon", date: Date().addingTimeInterval(60))
        delayed.todayEvents = [soon]
        delayed.updateClock()
        AppState.shared.presentationPreferences[.calendarReminder].enabled = false
        delayed.refreshReminderSchedule()
        precondition(delayed.reminderEvent == nil && AppState.shared.presentedCount == 0, "Disabled reminders were presented")
        AppState.shared.presentationPreferences[.calendarReminder].enabled = true
        delayed.refreshReminderSchedule()
        precondition(delayed.reminderEvent == soon && AppState.shared.presentedCount == 1, "Re-enabled reminders were not scheduled")
        precondition(delayed.featuredEvent == soon, "Reminder summary did not show the reminding event")
        AppState.shared.presentationPreferences[.calendarReminder].enabled = false
        delayed.refreshReminderSchedule()
        precondition(delayed.reminderEvent == nil, "Disabling reminders retained the current reminder")
        AppState.shared.presentationPreferences[.calendarReminder].enabled = true
        delayed.refreshReminderSchedule()
        precondition(AppState.shared.presentedCount == 1, "Preference changes replayed an already-delivered reminder")
        let later = event("later", date: Date().addingTimeInterval(120))
        delayed.todayEvents = [later]
        delayed.updateClock()
        delayed.refreshReminderSchedule()
        precondition(delayed.reminderEvent == later)
        delayed.updateClock(now: later.startDate)
        precondition(delayed.reminderEvent == nil && delayed.featuredEvent == later, "Started reminder did not transition to the ongoing meeting")
        delayed.setEnabled(false)
        for _ in 0..<100 { await Task.yield() }
        await CalendarEventService.shared.completeAll(after: 8)
        UserDefaults.standard.removeObject(forKey: "calendar.enabledCalendarIDs")
        print("PASS: production Calendar delayed catalog preserves hide selection, filters, duplicates, full snapshot equality, latest-date wins, disable/re-enable, authorization revocation, reminder policy and meeting links")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notchx-calendar-') as directory:
    source = Path(directory) / 'CalendarChecks.swift'
    binary = Path(directory) / 'CalendarChecks'
    source.write_text(stubs + production_defaults + models + manager + checks)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-module-cache-path', str(Path(directory) / 'module-cache'), '-swift-version', '5', '-strict-concurrency=complete', '-warnings-as-errors', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=20)
