import Foundation
import CoreLocation
import XCTest
@testable import NotchX

private final class WeatherFixtureProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var handler: (URLRequest) -> (Int, Data) = { _ in (500, Data()) }
    static func respond(_ handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock(); self.handler = handler; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        let (code, data) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class SuspendedCitySearchProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var started: XCTestExpectation?
    private static var cancelled: XCTestExpectation?

    static func observe(started: XCTestExpectation?, cancelled: XCTestExpectation?) {
        lock.lock(); defer { lock.unlock() }
        self.started = started
        self.cancelled = cancelled
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "geocoding-api.open-meteo.com" {
            Self.lock.lock(); let started = Self.started; Self.lock.unlock()
            started?.fulfill()
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }
    }
    override func stopLoading() {
        guard request.url?.host == "geocoding-api.open-meteo.com" else { return }
        Self.lock.lock(); let cancelled = Self.cancelled; Self.lock.unlock()
        cancelled?.fulfill()
    }
}

private final class WeatherLocationProbe: CLLocationManager {
    private weak var testDelegate: (any CLLocationManagerDelegate)?
    // Do not let CLLocationManager emit a real initial authorization callback into the fixture.
    override var delegate: (any CLLocationManagerDelegate)? {
        get { testDelegate }
        set { testDelegate = newValue }
    }
    override var authorizationStatus: CLAuthorizationStatus { .denied }
    override func requestLocation() { XCTFail("A geocoding test must not sample the real location") }
}

private final class WeatherGeocodingProbe: WeatherReverseGeocodingRequest {
    var completion: (@MainActor (String?) -> Void)?
    private(set) var cancellationCount = 0

    func start(completion: @escaping @MainActor (String?) -> Void) { self.completion = completion }
    // Keep the callback so tests can deliver a late result even after cancellation.
    func cancel() { cancellationCount += 1 }
}

@MainActor
final class StageTwoModuleTests: XCTestCase {
    private func preferences() -> (UserDefaults, String) {
        let domain = "app.notchx.tests.stage2.\(UUID().uuidString)"
        return (UserDefaults(suiteName: domain)!, domain)
    }
    private func notice(_ id: String, app: String) -> IslandNotification {
        IslandNotification(sourceID: id, appName: app, bundleIdentifier: app, appIcon: "bell", appIconURL: nil,
                           title: id, body: id, senderName: nil, previewText: id, avatarURL: nil, timestamp: Date(), tapAction: nil)
    }
    func testNotificationFilteringAndPauseKeepModuleEnabledAndAllowedFeedReadable() {
        let (defaults, domain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        var alerts = 0
        let manager = NotificationManager(state: state, observesSystemEvents: false) { alerts += 1 }
        manager.setEnabled(true)
        manager.setApplicationMuted("app.muted", muted: true)
        manager.addNotification(notice("muted", app: "app.muted"))
        XCTAssertTrue(manager.recentNotifications.isEmpty)
        manager.pauseAlerts(for: 1800)
        manager.addNotification(notice("paused", app: "app.allowed"))
        XCTAssertEqual(manager.latestNotification?.id, "paused")
        XCTAssertEqual(alerts, 0)
        XCTAssertTrue(state.notificationsEnabled)
        manager.pauseAlerts(for: nil)
        manager.addNotification(notice("resumed", app: "app.allowed"))
        XCTAssertEqual(alerts, 1)
        let reopened = NotificationManager(state: state, observesSystemEvents: false, presentNotification: {})
        XCTAssertTrue(reopened.mutedApplicationIDs.contains("app.muted"))
        XCTAssertEqual(Set(reopened.knownApplications.map(\.id)), ["app.muted", "app.allowed"])
        manager.setEnabled(false)
    }

    func testMutingTheLastPendingApplicationRemovesItsIslandBadge() {
        let (defaults, domain) = preferences()
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        state.selectFullExpandedTab(.module(.builtIn(.weather)))
        state.currentState = .fullExpanded
        let manager = NotificationManager(state: state, observesSystemEvents: false)
        manager.setEnabled(true)
        defer { manager.setEnabled(false) }
        manager.addNotification(notice("pending", app: "app.allowed"))
        XCTAssertEqual(state.pendingIslandEvents, [.notification])
        manager.setApplicationMuted("app.allowed", muted: true)
        XCTAssertTrue(manager.recentNotifications.isEmpty)
        XCTAssertNil(manager.latestNotification)
        XCTAssertTrue(state.pendingIslandEvents.isEmpty)
    }

    func testCalendarActivityUsesTimedCurrentMeetingThenNextAndHonorsExactEnd() {
        let calendar = CalendarDisplayOption(id: "work", title: "Work", sourceID: "work", sourceTitle: "Work", colorComponents: [1, 0, 0, 1], type: .local)
        let now = Date(timeIntervalSince1970: 10000)
        func event(_ id: String, offset: Double, end: Double, allDay: Bool = false) -> CalendarEventSnapshot {
            CalendarEventSnapshot(eventIdentifier: id, title: id, startDate: now.addingTimeInterval(offset),
                                  endDate: now.addingTimeInterval(end), isAllDay: allDay, location: nil, notes: nil, calendar: calendar)
        }
        let current = event("current", offset: -300, end: 300)
        let next = event("next", offset: 600, end: 1200)
        let activity = CalendarActivity(events: [next, event("all-day", offset: -3600, end: 3600, allDay: true), current], now: now)
        XCTAssertEqual(activity.current, current)
        XCTAssertEqual(activity.next, next)
        XCTAssertNil(CalendarActivity(events: [current], now: current.endDate).current)
    }

    private func waitFor(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        try await NativeUI.waitFor("module fixture condition", file: file, line: line, until: predicate)
    }
    private var forecast: Data {
        Data(#"{"timezone":"Asia/Shanghai","current":{"temperature_2m":0,"apparent_temperature":0,"relative_humidity_2m":70,"wind_speed_10m":10,"weather_code":0,"is_day":1},"daily":{"temperature_2m_max":[1],"temperature_2m_min":[0],"uv_index_max":[2]},"hourly":{"time":["2026-10-19T23:00"],"temperature_2m":[0],"weather_code":[0],"is_day":[0],"precipitation_probability":[60]}}"#.utf8)
    }

    func testReverseGeocodingKeepsCurrentNamesAndRejectsSupersededResults() async throws {
        let (defaults, domain) = preferences()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeatherFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        var requests: [WeatherGeocodingProbe] = []
        func request(at index: Int) throws -> WeatherGeocodingProbe {
            try XCTUnwrap(requests.dropFirst(index).first, "Missing reverse-geocoding request \(index + 1)")
        }
        let manager = WeatherManager(session: session, preferenceStore: defaults, locationManager: WeatherLocationProbe(),
            makeReverseGeocodingRequest: { _ in
                let request = WeatherGeocodingProbe()
                requests.append(request)
                return request
            })
        defer { manager.setEnabled(false); session.invalidateAndCancel(); defaults.removePersistentDomain(forName: domain) }
        // A failed forecast leaves the refresh debounce open; all external I/O is stubbed.
        WeatherFixtureProtocol.respond { _ in (503, Data()) }
        manager.setEnabled(true)
        manager.fetchWeather(latitude: 31.2, longitude: 121.5)
        try await waitFor { !manager.isLoading }
        XCTAssertEqual(requests.count, 1)
        try XCTUnwrap(request(at: 0).completion)("Shanghai")
        XCTAssertEqual(manager.weather.locationName, "Shanghai")

        manager.fetchWeather(latitude: 31.2, longitude: 121.5)
        try await waitFor { !manager.isLoading }
        try XCTUnwrap(request(at: 1).completion)(nil)
        XCTAssertEqual(manager.weather.locationName, "Shanghai", "A failed lookup must preserve the known city")

        manager.fetchWeather(latitude: 35.7, longitude: 139.7)
        try await waitFor { !manager.isLoading }
        manager.fetchWeather(latitude: 48.9, longitude: 2.4)
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(try request(at: 2).cancellationCount, 1)
        try XCTUnwrap(request(at: 3).completion)("Paris")
        try XCTUnwrap(request(at: 2).completion)("Tokyo")
        XCTAssertEqual(manager.weather.locationName, "Paris")
    }

    func testReverseGeocodingCancelsOnDisableCityChangeRevocationAndDeinit() async throws {
        for action in ["disable", "manual city", "revoke", "deinit"] {
            let (defaults, domain) = preferences()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WeatherFixtureProtocol.self]
            let session = URLSession(configuration: configuration)
            let request = WeatherGeocodingProbe()
            let location = WeatherLocationProbe()
            var manager: WeatherManager? = WeatherManager(session: session, preferenceStore: defaults, locationManager: location,
                makeReverseGeocodingRequest: { _ in request })
            defer { manager?.setEnabled(false); session.invalidateAndCancel(); defaults.removePersistentDomain(forName: domain) }
            WeatherFixtureProtocol.respond { _ in (503, Data()) }
            manager?.setEnabled(true)
            manager?.fetchWeather(latitude: 31.2, longitude: 121.5)
            try await waitFor { manager?.isLoading == false }
            XCTAssertNotNil(request.completion)
            XCTAssertEqual(request.cancellationCount, 0, action)
            switch action {
            case "disable": manager?.setEnabled(false)
            case "manual city": manager?.selectCity(WeatherCity(name: "Paris", latitude: 48.9, longitude: 2.4))
            case "revoke": manager?.locationManagerDidChangeAuthorization(location)
            default: manager = nil
            }
            XCTAssertEqual(request.cancellationCount, 1, action)
            let name = manager?.weather.locationName
            try XCTUnwrap(request.completion)("Stale city")
            XCTAssertEqual(manager?.weather.locationName, name, action)
        }
    }

    func testManualWeatherWorksWithoutLocationPermissionAndRetainsLastGoodDataOnFailure() async throws {
        let (defaults, domain) = preferences()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeatherFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let manager = WeatherManager(session: session, preferenceStore: defaults)
        defer { manager.setEnabled(false); session.invalidateAndCancel(); defaults.removePersistentDomain(forName: domain) }
        let data = forecast
        WeatherFixtureProtocol.respond { request in
            request.url?.host == "air-quality-api.open-meteo.com" ? (200, Data(#"{"current":{"us_aqi":0}}"#.utf8)) : (200, data)
        }
        manager.selectCity(WeatherCity(name: "Shanghai", latitude: 31.2, longitude: 121.5))
        manager.setEnabled(true)
        try await waitFor { !manager.isLoading && manager.hasWeatherData }
        XCTAssertEqual(manager.weather.temperature, 0)
        XCTAssertEqual(manager.weather.locationName, "Shanghai")
        XCTAssertNotNil(manager.lastUpdated)
        XCTAssertTrue(manager.isStale(at: manager.lastUpdated!.addingTimeInterval(3601)))
        let lastUpdated = manager.lastUpdated
        WeatherFixtureProtocol.respond { _ in (503, Data()) }
        manager.requestLocationAndFetch()
        try await waitFor { !manager.isLoading && manager.errorMessage != nil }
        XCTAssertTrue(manager.hasWeatherData)
        XCTAssertEqual(manager.lastUpdated, lastUpdated)
        XCTAssertEqual(manager.weather.temperature, 0)
        manager.setEnabled(false)
        let reopened = WeatherManager(session: session, preferenceStore: defaults)
        XCTAssertEqual(reopened.selectedCity?.name, "Shanghai")
    }

    func testCitySearchAndSwitchResetOldForecastAndDisableCancelsWork() async throws {
        let (defaults, domain) = preferences()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeatherFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let manager = WeatherManager(session: session, preferenceStore: defaults)
        defer { manager.setEnabled(false); session.invalidateAndCancel(); defaults.removePersistentDomain(forName: domain) }
        let data = forecast
        WeatherFixtureProtocol.respond { request in
            if request.url?.host == "geocoding-api.open-meteo.com" {
                return (200, Data(#"{"results":[{"name":"Tokyo","latitude":35.7,"longitude":139.7,"country":"Japan"}]}"#.utf8))
            }
            return (200, data)
        }
        manager.selectCity(WeatherCity(name: "Shanghai", latitude: 31.2, longitude: 121.5))
        manager.setEnabled(true)
        try await waitFor { manager.hasWeatherData && !manager.isLoading }
        manager.searchCities("Tokyo")
        try await waitFor { !manager.isSearchingCities && !manager.cityResults.isEmpty }
        manager.selectCity(manager.cityResults[0])
        XCTAssertFalse(manager.hasWeatherData)
        XCTAssertNil(manager.lastUpdated)
        XCTAssertEqual(manager.selectedCity?.name, "Tokyo")
        manager.setEnabled(false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(manager.hasWeatherData)
        XCTAssertFalse(manager.isLoading)
        XCTAssertTrue(manager.cityResults.isEmpty)
    }

    func testDisablingWeatherCancelsPendingCitySearchBeforeReenable() async {
        let (defaults, domain) = preferences()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SuspendedCitySearchProtocol.self]
        let session = URLSession(configuration: configuration)
        let manager = WeatherManager(session: session, preferenceStore: defaults)
        let started = expectation(description: "City search started")
        let cancelled = expectation(description: "City search cancelled on disable")
        SuspendedCitySearchProtocol.observe(started: started, cancelled: cancelled)
        defer {
            manager.setEnabled(false)
            session.invalidateAndCancel()
            SuspendedCitySearchProtocol.observe(started: nil, cancelled: nil)
            defaults.removePersistentDomain(forName: domain)
        }
        manager.selectCity(WeatherCity(name: "Shanghai", latitude: 31.2, longitude: 121.5))
        manager.setEnabled(true)
        manager.searchCities("Tokyo")
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(manager.isSearchingCities)
        manager.setEnabled(false)
        XCTAssertFalse(manager.isSearchingCities)
        XCTAssertTrue(manager.cityResults.isEmpty)
        await fulfillment(of: [cancelled], timeout: 3)
        manager.setEnabled(true)
        XCTAssertFalse(manager.isSearchingCities)
        XCTAssertTrue(manager.cityResults.isEmpty)
        XCTAssertNil(manager.citySearchError)
        XCTAssertEqual(manager.selectedCity?.name, "Shanghai")
    }

    func testRapidWeatherTogglesDoNotResurrectRegistrationsAndKeepLastGoodData() async throws {
        let (defaults, domain) = preferences()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeatherFixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        let manager = WeatherManager(session: session, preferenceStore: defaults, scheduler: { scheduler })
        defer { manager.setEnabled(false); scheduler.shutdown(); session.invalidateAndCancel(); defaults.removePersistentDomain(forName: domain) }
        let data = forecast
        WeatherFixtureProtocol.respond { request in
            request.url?.host == "air-quality-api.open-meteo.com" ? (200, Data(#"{"current":{"us_aqi":0}}"#.utf8)) : (200, data)
        }
        manager.selectCity(WeatherCity(name: "Shanghai", latitude: 31.2, longitude: 121.5))
        manager.setEnabled(true)
        try await waitFor { manager.hasWeatherData && !manager.isLoading && scheduler.jobCountForTesting == 1 }
        let lastUpdated = manager.lastUpdated
        for _ in 0..<5 {
            manager.setEnabled(false)
            manager.setEnabled(true)
        }
        manager.setEnabled(false)
        try await waitFor { scheduler.jobCountForTesting == 0 }
        XCTAssertEqual(scheduler.scheduledTimerCountForTesting, 0)
        XCTAssertFalse(manager.isLoading)
        XCTAssertTrue(manager.hasWeatherData)
        XCTAssertEqual(manager.lastUpdated, lastUpdated)
        manager.setEnabled(true)
        try await waitFor { scheduler.jobCountForTesting == 1 }
        XCTAssertEqual(scheduler.jobCountForTesting, 1)
    }
}
