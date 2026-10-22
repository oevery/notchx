import Foundation
import EventKit
import Combine
import CoreGraphics

private extension Int {
    var nonZero: Int? { self == 0 ? nil : self }
}

// Only value snapshots leave the service; EventKit objects and predicates stay isolated.
private actor CalendarEventService {
    private lazy var store = EKEventStore()

    func calendars() -> [CalendarDisplayOption] {
        guard !Task.isCancelled else { return [] }
        return store.calendars(for: .event).map(snapshot)
    }

    func events(start: Date, end: Date) -> [CalendarEventSnapshot] {
        guard !Task.isCancelled else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate)
        guard !Task.isCancelled else { return [] }
        return events.compactMap { event in
            guard let calendar = event.calendar else { return nil }
            return CalendarEventSnapshot(
                eventIdentifier: event.eventIdentifier,
                title: event.title,
                startDate: event.startDate,
                endDate: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location,
                notes: event.notes,
                calendar: snapshot(calendar), meetingURL: event.url
            )
        }
    }

    private func snapshot(_ calendar: EKCalendar) -> CalendarDisplayOption {
        let rgb = calendar.cgColor.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)
        let components = rgb?.components ?? [0.5, 0.5, 0.5, 1]
        return CalendarDisplayOption(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            sourceID: calendar.source.sourceIdentifier,
            sourceTitle: calendar.source.title,
            colorComponents: components.map { Double($0) },
            type: CalendarKind(rawValue: calendar.type.rawValue) ?? .unknown
        )
    }
}

extension CalendarDisplayOption {
    var color: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: colorComponents.map { CGFloat($0) })!
    }
}

@MainActor
final class CalendarManager: ObservableObject {
    static let shared = CalendarManager()
    var remindersEnabled: () -> Bool = { true }
    var onReminderPresented: (() -> Void)?
    var onReminderCleared: (() -> Void)?
    var onReminderSnoozed: (() -> Void)?

    @Published var todayEvents: [CalendarEventSnapshot] = []
    @Published var nextEvent: CalendarEventSnapshot?
    @Published private(set) var currentEvent: CalendarEventSnapshot?
    @Published private(set) var reminderEvent: CalendarEventSnapshot?
    @Published private(set) var clockNow = Date()
    var featuredEvent: CalendarEventSnapshot? { reminderEvent ?? currentEvent ?? nextEvent }
    var featuredCountdown: String? {
        if let reminderEvent { return L10n.format("in %d min", max(1, Int(ceil(reminderEvent.startDate.timeIntervalSince(clockNow) / 60)))) }
        if let currentEvent { return L10n.format("%d min remaining", max(1, Int(ceil(currentEvent.endDate.timeIntervalSince(clockNow) / 60)))) }
        return nextEventCountdown
    }
    @Published var hasAccess: Bool = false
    @Published var authorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @Published var displayedMonthStart: Date = startOfMonth(for: Date()) {
        didSet { prefetchDatesWithEventsIfNeeded() }
    }
    @Published var selectedDate: Date = Date()
    @Published var selectedDateEvents: [CalendarEventSnapshot] = []
    @Published var upcomingWeekEvents: [(date: Date, events: [CalendarEventSnapshot])] = []
    @Published var calendarSourceGroups: [CalendarSourceGroup] = []
    @Published var hideBirthdays: Bool = SettingsDefaults.Calendar.hideBirthdays.read() {
        didSet {
            UserDefaults.standard.set(hideBirthdays, forKey: SettingsDefaults.Calendar.hideBirthdays.key)
            refreshEventsAfterPreferenceChange()
        }
    }
    @Published var hideHolidays: Bool = SettingsDefaults.Calendar.hideHolidays.read() {
        didSet {
            UserDefaults.standard.set(hideHolidays, forKey: SettingsDefaults.Calendar.hideHolidays.key)
            refreshEventsAfterPreferenceChange()
        }
    }
    @Published var collapseDuplicates: Bool = SettingsDefaults.Calendar.collapseDuplicates.read() {
        didSet {
            UserDefaults.standard.set(collapseDuplicates, forKey: SettingsDefaults.Calendar.collapseDuplicates.key)
            refreshEventsAfterPreferenceChange()
        }
    }

    private let service = CalendarEventService()
    private var refreshToken: ModuleRefreshToken?
    private var clockRefreshToken: ModuleRefreshToken?
    private var snoozeTask: Task<Void, Never>?
    private var isEnabled = false
    private var requestGeneration = UUID()
    private var preEventTask: Task<Void, Never>?
    private var reminderLedger = CalendarReminderLedger()
    private enum Query: Hashable { case calendars, today, selectedDate, upcoming, month }
    private var fetchTasks: [Query: Task<Void, Never>] = [:]
    private var fetchIDs: [Query: UUID] = [:]
    private var isObservingStoreChanges = false
    private var hasLoadedCalendars = false
    private let enabledCalendarIDsKey = SettingsDefaults.Calendar.enabledCalendarIDsKey
    @Published var datesWithEvents: Set<Date> = []

    var preEventMinutes: Int {
        get { UserDefaults.standard.integer(forKey: SettingsDefaults.Calendar.preEventMinutes.key).nonZero ?? SettingsDefaults.Calendar.preEventMinutes.value }
        set {
            UserDefaults.standard.set(max(1, min(60, newValue)), forKey: SettingsDefaults.Calendar.preEventMinutes.key)
            schedulePreEventNotification()
        }
    }

    var lookaheadDays: Int {
        get { UserDefaults.standard.integer(forKey: SettingsDefaults.Calendar.lookaheadDays.key).nonZero ?? SettingsDefaults.Calendar.lookaheadDays.value }
        set {
            UserDefaults.standard.set(max(1, min(30, newValue)), forKey: SettingsDefaults.Calendar.lookaheadDays.key)
            fetchUpcomingWeekEvents()
        }
    }

    private init() {
        // Constructing an inactive module (for example from Settings) is inert.
        // Activation owns fetches, subscriptions and host presentation changes.
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        hasAccess = Self.isAuthorized(authorizationStatus)
    }

    /// Re-read only display preferences; refresh helpers remain gated on existing access/enablement.
    func reloadRestoredPreferences() {
        hideBirthdays = SettingsDefaults.Calendar.hideBirthdays.read()
        hideHolidays = SettingsDefaults.Calendar.hideHolidays.read()
        collapseDuplicates = SettingsDefaults.Calendar.collapseDuplicates.read()
        refreshEventsAfterPreferenceChange()
    }

    // MARK: - Access

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        requestGeneration = UUID()
        refreshAccessStatus()
        if !enabled {
            remindersEnabled = { true }
            onReminderPresented = nil
            onReminderCleared = nil
            onReminderSnoozed = nil
        }
    }

    func refreshAccessStatus() {
        // Invalidate pending fetches when authorization changes, including revocation.
        requestGeneration = UUID()
        cancelFetches()
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        hasAccess = Self.isAuthorized(authorizationStatus)
        if hasAccess && isEnabled {
            reloadCalendars()
            registerRefresh()
            observeStoreChanges()
        } else {
            clearEvents()
            stopRefresh()
        }
    }

    func requestAccess() {
        Task { [weak self] in
            await PermissionState.shared.request(.calendar)
            self?.refreshAccessStatus()
        }
    }

    func openCalendarSettings() {
        PermissionsManager.shared.openCalendarSettings()
    }

    private static func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .fullAccess:
            return true
        default:
            return false
        }
    }

    // MARK: - Calendar Sources

    var hasCustomCalendarSelection: Bool {
        UserDefaults.standard.object(forKey: enabledCalendarIDsKey) != nil
    }

    var enabledCalendarIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: enabledCalendarIDsKey) ?? [])
    }

    func isCalendarEnabled(_ calendarID: String) -> Bool {
        guard hasCustomCalendarSelection else { return true }
        return enabledCalendarIDs.contains(calendarID)
    }

    func setCalendar(_ calendarID: String, enabled: Bool) {
        var selectedIDs = hasCustomCalendarSelection ? enabledCalendarIDs : Set(allCalendarIDs)
        if enabled {
            selectedIDs.insert(calendarID)
        } else {
            selectedIDs.remove(calendarID)
        }

        UserDefaults.standard.set(allCalendarIDs.filter { selectedIDs.contains($0) }, forKey: enabledCalendarIDsKey)
        refreshEventsAfterPreferenceChange()
    }

    func hideCalendar(for event: CalendarEventSnapshot) {
        setCalendar(event.calendar.id, enabled: false)
    }

    func reloadCalendars() {
        guard hasAccess, isEnabled else {
            calendarSourceGroups = []
            return
        }

        hasLoadedCalendars = false
        let generation = requestGeneration
        let id = beginFetch(.calendars)
        fetchTasks[.calendars] = Task { [weak self, service] in
            let calendars = await service.calendars()
            guard !Task.isCancelled, let self, self.canPublish(.calendars, id: id, generation: generation) else { return }
            self.finishFetch(.calendars)
            let grouped = Dictionary(grouping: calendars, by: \.sourceID)
            self.calendarSourceGroups = grouped.map { sourceID, calendars in
                let sorted = calendars.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                return CalendarSourceGroup(id: sourceID, title: sorted.first?.sourceTitle ?? "Calendars", calendars: sorted)
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            // Event actions construct a complete calendar selection. Publish events
            // only after that catalog exists, including when initial loading is slow.
            self.hasLoadedCalendars = true
            self.fetchTodayEvents()
            self.prefetchDatesWithEventsIfNeeded()
        }
    }

    private var allCalendarIDs: [String] {
        calendarSourceGroups.flatMap { $0.calendars.map(\.id) }
    }

    // MARK: - Fetching

    func fetchTodayEvents() {
        guard hasAccess, isEnabled else { return }

        let cal = Foundation.Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        fetch(.today, start: startOfDay, end: endOfDay) { [weak self] events in
            guard let self else { return }
            let visibleEvents = self.visibleEvents(from: events)
            if self.todayEvents != visibleEvents {
                self.todayEvents = visibleEvents
            }
            self.updateClock()
            if let reminder = self.reminderEvent, !visibleEvents.contains(reminder) { self.ignoreReminder() }
            self.schedulePreEventNotification()
            self.fetchEventsForSelectedDate()
            self.fetchUpcomingWeekEvents()
        }
    }

    // MARK: - Pre-Event Timer

    func refreshReminderSchedule() {
        if !remindersEnabled() { ignoreReminder() }
        schedulePreEventNotification()
    }

    private func schedulePreEventNotification() {
        preEventTask?.cancel()

        guard isEnabled, remindersEnabled(), let next = nextEvent else { return }
        let triggerDate = next.startDate.addingTimeInterval(-Double(preEventMinutes * 60))
        let interval = triggerDate.timeIntervalSinceNow

        guard interval > 0 else {
            // Event is within the notification window
            if next.startDate.timeIntervalSinceNow > 0 {
                presentPreEventReminder(for: next)
            }
            return
        }

        let generation = requestGeneration
        preEventTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(interval), tolerance: .seconds(min(30, max(1, interval * 0.05))))
            } catch { return }
            guard !Task.isCancelled, let self, self.isEnabled, self.requestGeneration == generation else { return }
            self.fetchTodayEvents()
            self.presentPreEventReminder(for: next)
        }
    }

    private func presentPreEventReminder(for event: CalendarEventSnapshot) {
        guard isEnabled, hasAccess, remindersEnabled(),
              reminderLedger.claim(event, now: Date()) else { return }
        reminderEvent = event
        onReminderPresented?()
    }

    func updateClock(now: Date = Date()) {
        clockNow = now
        if let reminderEvent, reminderEvent.startDate <= now { ignoreReminder() }
        let activity = CalendarActivity(events: todayEvents, now: now)
        currentEvent = activity.current
        nextEvent = activity.next
    }

    func ignoreReminder() {
        snoozeTask?.cancel()
        snoozeTask = nil
        reminderEvent = nil
        onReminderCleared?()
    }

    func snoozeReminder() {
        guard isEnabled, hasAccess, let event = reminderEvent else { return }
        let delay = min(300, event.startDate.timeIntervalSinceNow - 1)
        guard delay > 0 else { ignoreReminder(); return }
        ignoreReminder()
        snoozeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard !Task.isCancelled, let self, self.isEnabled, self.hasAccess,
                  self.todayEvents.contains(event), event.startDate > Date(),
                  self.remindersEnabled() else { return }
            self.reminderEvent = event
            self.snoozeTask = nil
            self.onReminderPresented?()
        }
        onReminderSnoozed?()
    }

    // MARK: - Refresh

    private func registerRefresh() {
        guard isEnabled, refreshToken == nil else { return }

        refreshToken = ModuleRefreshScheduler.shared.register(
            id: "calendar.refresh",
            name: "Calendar fallback refresh",
            module: .builtIn(.calendar),
            policy: .interval(600, tolerance: 120),
            enabled: { [weak self] in self?.isEnabled == true && self?.hasAccess == true }
        ) { [weak self] in
            self?.fetchTodayEvents()
        }
        clockRefreshToken = ModuleRefreshScheduler.shared.register(
            id: "calendar.clock", name: "Visible calendar countdown", module: .builtIn(.calendar),
            policy: .visibleOnly(30, tolerance: 2), enabled: { [weak self] in self?.isEnabled == true && self?.hasAccess == true }
        ) { [weak self] in self?.updateClock() }
    }

    private func observeStoreChanges() {
        guard !isObservingStoreChanges else { return }
        isObservingStoreChanges = true

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(dayChanged),
            name: .NSCalendarDayChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(eventStoreChanged),
            name: .EKEventStoreChanged,
            object: nil
        )
    }

    private func stopRefresh() {
        preEventTask?.cancel()
        preEventTask = nil
        ModuleRefreshScheduler.shared.unregister(refreshToken)
        refreshToken = nil
        ModuleRefreshScheduler.shared.unregister(clockRefreshToken)
        clockRefreshToken = nil
        ignoreReminder()
        NotificationCenter.default.removeObserver(self, name: .NSCalendarDayChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .EKEventStoreChanged, object: nil)
        isObservingStoreChanges = false
    }

    @objc nonisolated private func dayChanged() {
        Task { @MainActor [weak self] in self?.fetchTodayEvents() }
    }

    @objc nonisolated private func eventStoreChanged() {
        Task { @MainActor [weak self] in self?.refreshAccessStatus() }
    }

    // MARK: - Helpers

    func showPreviousMonth() {
        changeDisplayedMonth(by: -1)
    }

    func showNextMonth() {
        changeDisplayedMonth(by: 1)
    }

    func resetDisplayedMonthToCurrent() {
        displayedMonthStart = Self.startOfMonth(for: Date())
    }

    var nextEventCountdown: String? {
        guard isEnabled, let next = nextEvent else { return nil }
        let interval = next.startDate.timeIntervalSince(clockNow)
        guard interval > 0 else { return L10n.text("now") }

        let minutes = Int(interval / 60)
        if minutes < 60 {
            return L10n.format("in %d min", minutes)
        }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        return L10n.format("in %dh %dm", hours, remainingMinutes)
    }

    func joinURL(for event: CalendarEventSnapshot) -> URL? {
        if let url = event.meetingURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { return url }
        // Check notes and location for meeting URLs
        let searchTexts = [event.notes, event.location].compactMap { $0 }
        let patterns = [
            "https://[\\w.-]+\\.zoom\\.us/[\\w/?=&-]+",
            "https://meet\\.google\\.com/[\\w-]+",
            "https://teams\\.microsoft\\.com/[\\w/?=&-]+",
            "https?://[^\\s<>]+"
        ]

        for text in searchTexts {
            for pattern in patterns {
                if let range = text.range(of: pattern, options: .regularExpression) {
                    return URL(string: String(text[range]))
                }
            }
        }
        return nil
    }

    func selectDate(_ date: Date) {
        selectedDate = date
        fetchEventsForSelectedDate()
    }

    func fetchEventsForSelectedDate() {
        guard hasAccess, isEnabled else { return }
        let cal = Foundation.Calendar.current
        let startOfDay = cal.startOfDay(for: selectedDate)
        let endOfDay = cal.date(byAdding: .day, value: 1, to: startOfDay)!
        fetch(.selectedDate, start: startOfDay, end: endOfDay) { [weak self] events in
            guard let self else { return }
            self.selectedDateEvents = self.visibleEvents(from: events)
        }
    }

    func fetchUpcomingWeekEvents() {
        guard hasAccess, isEnabled else { return }
        let cal = Foundation.Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!
        let weekEnd = cal.date(byAdding: .day, value: lookaheadDays, to: tomorrow)!
        fetch(.upcoming, start: tomorrow, end: weekEnd) { [weak self] allEvents in
            guard let self else { return }
            let visibleEvents = self.visibleEvents(from: allEvents)
            var eventsByDay: [Date: [CalendarEventSnapshot]] = [:]
            for event in visibleEvents {
                for day in event.occurringDays(from: tomorrow, to: weekEnd, calendar: cal) {
                    eventsByDay[day, default: []].append(event)
                }
            }
            self.upcomingWeekEvents = eventsByDay.keys.sorted().map { (date: $0, events: eventsByDay[$0] ?? []) }
            self.prefetchDatesWithEventsIfNeeded()
        }
    }

    func hasEvents(on date: Date) -> Bool {
        let startOfDay = Calendar.current.startOfDay(for: date)
        return datesWithEvents.contains(startOfDay)
    }

    func prefetchDatesWithEventsIfNeeded() {
        guard hasAccess, isEnabled else { return }
        let cal = Calendar.current
        // Fetch a 9-week window centered on the displayed month to cover all calendar grid cells.
        let rangeStart = cal.date(byAdding: .day, value: -14, to: displayedMonthStart)!
        let rangeEnd = cal.date(byAdding: .day, value: 49, to: displayedMonthStart)!
        fetch(.month, start: rangeStart, end: rangeEnd) { [weak self] events in
            guard let self else { return }
            self.datesWithEvents = Set(self.visibleEvents(from: events).flatMap {
                $0.occurringDays(from: rangeStart, to: rangeEnd, calendar: cal)
            })
        }
    }

    private func beginFetch(_ query: Query) -> UUID {
        fetchTasks[query]?.cancel()
        let id = UUID()
        fetchIDs[query] = id
        return id
    }

    private func canPublish(_ query: Query, id: UUID, generation: UUID) -> Bool {
        isEnabled && hasAccess && requestGeneration == generation && fetchIDs[query] == id
    }

    private func finishFetch(_ query: Query) {
        fetchTasks.removeValue(forKey: query)
        fetchIDs.removeValue(forKey: query)
    }

    private func fetch(_ query: Query, start: Date, end: Date, apply: @escaping @MainActor ([CalendarEventSnapshot]) -> Void) {
        guard hasLoadedCalendars else { return }
        let generation = requestGeneration
        let id = beginFetch(query)
        fetchTasks[query] = Task { [weak self, service] in
            let events = await service.events(start: start, end: end)
            guard !Task.isCancelled, let self, self.canPublish(query, id: id, generation: generation) else { return }
            self.finishFetch(query)
            apply(events)
        }
    }

    private func cancelFetches() {
        fetchTasks.values.forEach { $0.cancel() }
        fetchTasks.removeAll()
        fetchIDs.removeAll()
    }

    private func refreshEventsAfterPreferenceChange() {
        guard hasAccess, isEnabled else { return }
        fetchTodayEvents()
        fetchEventsForSelectedDate()
        fetchUpcomingWeekEvents()
        prefetchDatesWithEventsIfNeeded()
    }

    private func clearEvents() {
        hasLoadedCalendars = false
        calendarSourceGroups = []
        todayEvents = []
        nextEvent = nil
        currentEvent = nil
        ignoreReminder()
        selectedDateEvents = []
        upcomingWeekEvents = []
        datesWithEvents = []
        preEventTask?.cancel()
        preEventTask = nil
    }

    private func visibleEvents(from events: [CalendarEventSnapshot]) -> [CalendarEventSnapshot] {
        CalendarEventFilter(
            enabledCalendarIDs: hasCustomCalendarSelection ? enabledCalendarIDs : nil,
            hideBirthdays: hideBirthdays,
            hideHolidays: hideHolidays,
            collapseDuplicates: collapseDuplicates
        ).visibleEvents(from: events)
    }

    private func changeDisplayedMonth(by offset: Int) {
        let calendar = Foundation.Calendar.current
        if let updated = calendar.date(byAdding: .month, value: offset, to: displayedMonthStart) {
            displayedMonthStart = Self.startOfMonth(for: updated)
        }
    }

    private static func startOfMonth(for date: Date) -> Date {
        let calendar = Foundation.Calendar.current
        let components = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: components) ?? date
    }

    deinit {
        snoozeTask?.cancel()
        let clockToken = clockRefreshToken
        fetchTasks.values.forEach { $0.cancel() }
        let token = refreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(token)
            ModuleRefreshScheduler.shared.unregister(clockToken)
        }
        preEventTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
