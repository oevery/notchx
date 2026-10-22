import Foundation
import XCTest
@testable import NotchX

final class ModuleReliabilityTests: XCTestCase {
    @MainActor
    func testWeatherSnapshotsRelocalizeWithoutFetchingAgainAndShareTemperatureFormatting() {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: L10n.preferenceKey)
        defer {
            if let previous { defaults.set(previous, forKey: L10n.preferenceKey) }
            else { defaults.removeObject(forKey: L10n.preferenceKey) }
        }
        defaults.set(AppLanguage.english.rawValue, forKey: L10n.preferenceKey)
        let manager = WeatherManager()
        let now = ISO8601DateFormatter().date(from: "2026-10-18T23:30:00+08:00")!
        XCTAssertTrue(manager.parseWeatherResponse(weatherResponse(), now: now))
        let english = manager.weather.condition
        let dates = manager.weather.hourlyForecast.map(\.id)
        defaults.set(AppLanguage.simplifiedChinese.rawValue, forKey: L10n.preferenceKey)
        XCTAssertNotEqual(manager.weather.condition, english)
        XCTAssertEqual(manager.weather.condition, L10n.text("Clear Sky"))
        XCTAssertEqual(manager.weather.hourlyForecast.map(\.id), dates)
        XCTAssertEqual(manager.weather.hourlyForecast.first?.formattedHour(at: now), L10n.text("Now"))
        XCTAssertEqual(TemperatureUnit.fahrenheit.formatted(0), "32°F")
        XCTAssertEqual(TemperatureUnit.celsius.formatted(-0.1), "0°C")
        XCTAssertEqual(TemperatureUnit.celsius.formatted(25.6, showsUnit: false), "26°")
        XCTAssertEqual(TemperatureUnit.celsius.formatted(.nan), "—")
    }

    func testCalendarPresentationHonorsLanguageHourCycleAndTimezoneAcrossSurfaces() {
        let start = Date(timeIntervalSince1970: 15 * 3600 + 5 * 60)
        let end = start.addingTimeInterval(3600)
        let zone = TimeZone(secondsFromGMT: 0)!
        let english = CalendarPresentation.timeRange(start: start, end: end, locale: Locale(identifier: "en_US"), timeZone: zone)
        let chinese = CalendarPresentation.timeRange(start: start, end: end, locale: Locale(identifier: "zh_CN"), timeZone: zone)
        XCTAssertTrue(english.contains("3:05"))
        XCTAssertTrue(chinese.contains("15:05"))
        XCTAssertNotEqual(english, chinese)
    }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }

    private func date(_ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour))!
    }

    private func event(start: Date, end: Date, allDay: Bool = false) -> CalendarEventSnapshot {
        CalendarEventSnapshot(eventIdentifier: "meeting", title: "Meeting", startDate: start, endDate: end,
                              isAllDay: allDay, location: nil, notes: nil,
                              calendar: CalendarDisplayOption(id: "work", title: "Work", sourceID: "account",
                                                              sourceTitle: "Account", colorComponents: [1, 0, 0, 1], type: .calDAV))
    }

    func testMultiDayCalendarEventsIncludeEveryVisibleDayButExcludeMidnightEnd() {
        let value = event(start: date(17, hour: 18), end: date(21))
        XCTAssertEqual(value.occurringDays(from: date(18), to: date(23), calendar: calendar),
                       [date(18), date(19), date(20)])
        XCTAssertEqual(value.occurringDays(from: date(18), to: date(20), calendar: calendar), [date(18), date(19)])
        XCTAssertTrue(value.occurringDays(from: date(21), to: date(23), calendar: calendar).isEmpty)
    }

    func testCalendarDaysFollowDaylightSavingInsteadOfAssuming24Hours() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3))!
        let days = event(start: start, end: end).occurringDays(from: start, to: end, calendar: calendar)
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days[2].timeIntervalSince(days[1]), 25 * 3600)
    }

    func testCalendarReminderDoesNotRepeatOnRefreshAndAllowsRescheduledEvents() {
        var ledger = CalendarReminderLedger()
        let value = event(start: date(19, hour: 10), end: date(19, hour: 11))
        XCTAssertTrue(ledger.claim(value, now: date(19, hour: 9)))
        XCTAssertFalse(ledger.claim(value, now: date(19, hour: 9)))
        XCTAssertFalse(ledger.claim(value, now: value.startDate))
        let rescheduled = event(start: date(19, hour: 12), end: date(19, hour: 13))
        XCTAssertTrue(ledger.claim(rescheduled, now: date(19, hour: 9)))
        XCTAssertFalse(ledger.claim(event(start: date(20), end: date(21), allDay: true), now: date(19)))
    }

    private func weatherResponse() -> [String: Any] {
        let value: [String: Any] = ["timezone": "Asia/Shanghai",
         "current": ["temperature_2m": 0.0, "apparent_temperature": 0.0, "relative_humidity_2m": 70,
                     "wind_speed_10m": 0.0, "weather_code": 0, "is_day": 0],
         "daily": ["temperature_2m_max": [0.0], "temperature_2m_min": [0.0], "uv_index_max": [0.0]],
         "hourly": ["time": ["2026-10-18T22:00", "2026-10-18T23:00", "2026-10-19T00:00",
                               "2026-10-19T01:00", "2026-10-19T02:00", "2026-10-19T03:00", "2026-10-19T04:00"],
                    "temperature_2m": [0.0, 0, 1, 2, 3, 4, 5],
                    "weather_code": [0, 0, 0, 0, 0, 0, 0], "is_day": [0, 0, 0, 0, 0, 0, 0]]]
        return try! JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: value)) as! [String: Any]
    }

    @MainActor
    func testWeatherAcceptsRealZeroValuesAndKeepsSixHoursAcrossMidnightInForecastTimezone() {
        let manager = WeatherManager()
        XCTAssertFalse(manager.hasWeatherData)
        let now = ISO8601DateFormatter().date(from: "2026-10-18T23:30:00+08:00")!
        XCTAssertTrue(manager.parseWeatherResponse(weatherResponse(), now: now))
        XCTAssertTrue(manager.hasWeatherData)
        XCTAssertEqual(manager.weather.temperature, 0)
        XCTAssertEqual(manager.weather.hourlyForecast.count, 6)
        XCTAssertEqual(manager.weather.hourlyForecast.first?.id, now.addingTimeInterval(-1800))
        XCTAssertEqual(manager.weather.hourlyForecast.last?.temperature, 5)
        XCTAssertEqual(manager.weather.conditionIcon, "moon.stars.fill")
        XCTAssertTrue(manager.weather.hourlyForecast.allSatisfy { $0.conditionIcon == "moon.stars.fill" })
        XCTAssertNil(manager.weather.aqi)
    }

    @MainActor
    func testInvalidWeatherResponsePreservesLastValidSnapshot() {
        let manager = WeatherManager()
        XCTAssertFalse(manager.parseWeatherResponse(["error": true]))
        XCTAssertFalse(manager.hasWeatherData)
        let now = ISO8601DateFormatter().date(from: "2026-10-18T23:30:00+08:00")!
        XCTAssertTrue(manager.parseWeatherResponse(weatherResponse(), now: now))
        let previousIDs = manager.weather.hourlyForecast.map(\.id)
        var invalid = weatherResponse()
        invalid["hourly"] = ["time": ["2026-10-19T00:00"], "temperature_2m": [], "weather_code": []]
        XCTAssertFalse(manager.parseWeatherResponse(invalid, now: now))
        XCTAssertEqual(manager.weather.hourlyForecast.map(\.id), previousIDs)
        XCTAssertTrue(manager.hasWeatherData)
    }

    private func notification(_ id: String, body: String? = nil, sender: String = "Sender", timestamp: Date = Date()) -> IslandNotification {
        let body = body ?? "Body \(id)"
        return IslandNotification(sourceID: id, appName: "Example", bundleIdentifier: "app.example", appIcon: "bell",
                                  appIconURL: nil, title: id, body: body, senderName: sender, previewText: body,
                                  avatarURL: nil, timestamp: timestamp, tapAction: nil)
    }

    @MainActor
    func testDismissalDoesNotSuppressOtherSendersOrLaterMessagesWithTheSameText() {
        let domain = "app.notchx.tests.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        let manager = NotificationManager(state: state, observesSystemEvents: false, presentNotification: {})
        manager.setEnabled(true)
        let timestamp = Date()
        manager.addNotification(notification("first", body: "Shared text", sender: "A", timestamp: timestamp))
        manager.clearAll()
        manager.addNotification(notification("other-sender", body: "Shared text", sender: "B", timestamp: timestamp))
        XCTAssertEqual(manager.latestNotification?.id, "other-sender")
        manager.addNotification(notification("later", body: "Shared text", sender: "A", timestamp: timestamp.addingTimeInterval(30)))
        XCTAssertEqual(manager.latestNotification?.id, "later")
        manager.addNotification(notification("replayed", body: "Shared text", sender: "A", timestamp: timestamp.addingTimeInterval(1)))
        XCTAssertEqual(manager.recentNotifications.map(\.id), ["later", "other-sender"])
        manager.setEnabled(false)
    }

    @MainActor
    func testNotificationClearIsOrderedAndDismissedItemsDoNotReappear() {
        let domain = "app.notchx.tests.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        var presentations = 0
        let manager = NotificationManager(state: state, observesSystemEvents: false) { presentations += 1 }
        manager.setEnabled(true)
        manager.addNotification(notification("first"))
        XCTAssertEqual(manager.latestNotification?.id, "first")
        manager.clearAll()
        manager.addNotification(notification("first"))
        XCTAssertTrue(manager.recentNotifications.isEmpty)
        XCTAssertNil(manager.latestNotification)
        XCTAssertEqual(presentations, 1)
        manager.addNotification(notification("second"))
        XCTAssertEqual(manager.latestNotification?.id, "second")
        manager.setEnabled(false)
        manager.addNotification(notification("disabled"))
        XCTAssertEqual(manager.latestNotification?.id, "second")
        XCTAssertEqual(presentations, 2)
    }

    @MainActor
    func testNotificationPreferencesFilterFeedAndRetentionImmediately() {
        let domain = "app.notchx.tests.notifications.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        state.notificationMaxRetainedItems = 2
        let manager = NotificationManager(state: state, observesSystemEvents: false, presentNotification: {})
        manager.setEnabled(true)
        for id in ["a", "b", "c"] { manager.addNotification(notification(id)) }
        XCTAssertEqual(manager.recentNotifications.map(\.id), ["c", "b"])
        state.setNotificationSource(.compatibleApps, enabled: false)
        manager.applyFeedPreferences()
        XCTAssertTrue(manager.recentNotifications.isEmpty)
        XCTAssertNil(manager.latestNotification)
        manager.addNotification(notification("filtered"))
        XCTAssertTrue(manager.recentNotifications.isEmpty)
        manager.setEnabled(false)
    }
}
