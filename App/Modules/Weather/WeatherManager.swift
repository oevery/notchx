import Foundation
import CoreLocation
import Combine
import MapKit

/// The network boundary stays replaceable without requesting location or contacting MapKit in tests.
protocol WeatherReverseGeocodingRequest: AnyObject {
    func start(completion: @escaping @MainActor (String?) -> Void)
    func cancel()
}

private final class MapKitWeatherReverseGeocodingRequest: WeatherReverseGeocodingRequest {
    private let request: MKReverseGeocodingRequest

    init?(_ location: CLLocation) {
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        self.request = request
    }

    func start(completion: @escaping @MainActor (String?) -> Void) {
        request.getMapItems { items, _ in
            completion(items?.first?.addressRepresentations?.cityName)
        }
    }

    func cancel() { request.cancel() }
}

struct WeatherData {
    var temperature: Double = 0
    var temperatureHigh: Double = 0
    var temperatureLow: Double = 0
    var conditionCode = 0
    var condition: String { WeatherCondition.name(for: conditionCode) }
    var conditionIcon: String = "sun.max.fill"
    var locationName: String = ""
    var hourlyForecast: [HourlyWeather] = []
    var feelsLike: Double = 0
    var humidity: Int = 0
    var windSpeed: Double = 0
    var uvIndex: Double = 0
    var aqi: Int?
    var precipitationProbability: Int?
}

struct HourlyWeather: Identifiable {
    let id: Date
    let timeZone: TimeZone
    var hour: String { formattedHour(at: Date()) }
    func formattedHour(at now: Date, locale: Locale = L10n.locale) -> String {
        if id <= now, now < id.addingTimeInterval(3600) { return L10n.text("Now") }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("j")
        return formatter.string(from: id)
    }
    let temperature: Double
    let conditionIcon: String
    var precipitationProbability: Int? = nil
}

final class WeatherManager: NSObject, ObservableObject {
    static let shared = WeatherManager(scheduler: { .shared })

    @Published var weather = WeatherData()
    @Published var isLoading = false
    @Published private(set) var hasWeatherData = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var selectedCity: WeatherCity?
    @Published private(set) var authorizationStatus: CLAuthorizationStatus = .notDetermined
    @Published private(set) var cityResults: [WeatherCity] = []
    @Published private(set) var isSearchingCities = false
    @Published private(set) var citySearchError: String?
    private let session: URLSession
    private let preferenceStore: UserDefaults
    private let scheduler: @MainActor () -> ModuleRefreshScheduler?
    private var lifecycleGeneration = UUID()
    private var citySearchTask: Task<Void, Never>?
    private var citySearchID = UUID()

    private let locationManager: CLLocationManager
    private let makeReverseGeocodingRequest: (CLLocation) -> WeatherReverseGeocodingRequest?
    private var lastFetchTime: Date?
    private var refreshToken: ModuleRefreshToken?
    private var isEnabled = false
    private var requestGeneration = UUID()
    private var weatherTask: URLSessionDataTask?
    private var airQualityTask: URLSessionDataTask?
    private var geocodingRequest: WeatherReverseGeocodingRequest?

    init(session: URLSession = .shared, preferenceStore: UserDefaults = .standard,
         scheduler: @escaping @MainActor () -> ModuleRefreshScheduler? = { nil },
         locationManager: CLLocationManager = CLLocationManager(),
         makeReverseGeocodingRequest: @escaping (CLLocation) -> WeatherReverseGeocodingRequest? = { MapKitWeatherReverseGeocodingRequest($0) }) {
        self.session = session
        self.preferenceStore = preferenceStore
        self.scheduler = scheduler
        self.locationManager = locationManager
        self.makeReverseGeocodingRequest = makeReverseGeocodingRequest
        let storedCity = preferenceStore.data(forKey: WeatherCity.defaultsKey).flatMap { try? JSONDecoder().decode(WeatherCity.self, from: $0) }
        _selectedCity = Published(initialValue: storedCity?.isValid == true ? storedCity : nil)
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorizationStatus = locationManager.authorizationStatus
    }

    // MARK: - Location

    /// Only explicit user actions may request a new permission.
    func requestLocationAndFetch() {
        guard isEnabled else { return }
        lastFetchTime = nil
        if selectedCity != nil { refreshIfAuthorized(); return }
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        } else if locationManager.authorizationStatus == .denied || locationManager.authorizationStatus == .restricted {
            PermissionsManager.shared.request(.location)
        } else {
            cancelCitySearch()
            refreshIfAuthorized()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        lifecycleGeneration = UUID()
        if enabled {
            registerRefresh()
            refreshIfAuthorized()
        } else {
            requestGeneration = UUID()
            cancelCitySearch()
            locationManager.stopUpdatingLocation()
            weatherTask?.cancel()
            airQualityTask?.cancel()
            weatherTask = nil
            airQualityTask = nil
            cancelReverseGeocoding()
            isLoading = false
            let token = refreshToken
            refreshToken = nil
            let scheduler = scheduler
            Task { @MainActor in scheduler()?.unregister(token) }
        }
    }

    private func refreshIfAuthorized() {
        guard isEnabled, !isLoading else { return }
        if let lastFetchTime, Date().timeIntervalSince(lastFetchTime) < 300 { return }
        if let city = selectedCity { fetchWeather(latitude: city.latitude, longitude: city.longitude); return }
        switch locationManager.authorizationStatus {
        case .authorizedAlways:
            isLoading = true
            errorMessage = nil
            locationManager.requestLocation()
        default:
            break
        }
    }

    // MARK: - Fetching (Open-Meteo free API)

    func fetchWeather(latitude: Double, longitude: Double) {
        guard isEnabled, weatherTask == nil else { return }

        // Debounce: don't fetch more than once per 5 minutes
        if let lastFetch = lastFetchTime, Date().timeIntervalSince(lastFetch) < 300 {
            isLoading = false
            return
        }

        isLoading = true
        errorMessage = nil
        requestGeneration = UUID()
        weather.aqi = nil
        airQualityTask?.cancel()
        cancelReverseGeocoding()
        let generation = requestGeneration

        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)&current=temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day&hourly=temperature_2m,weather_code,is_day,precipitation_probability&daily=temperature_2m_max,temperature_2m_min,uv_index_max&wind_speed_unit=mph&timezone=auto&forecast_days=2"

        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }

        weatherTask = session.dataTask(with: URLRequest(url: url, timeoutInterval: 20)) { [weak self] data, response, error in
            defer { DispatchQueue.main.async {
                guard self?.requestGeneration == generation else { return }
                self?.isLoading = false
                self?.weatherTask = nil
            } }

            guard let data, error == nil, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
                DispatchQueue.main.async {
                    guard self?.requestGeneration == generation, self?.isEnabled == true else { return }
                    self?.errorMessage = L10n.text("Weather update failed. Try again.")
                }
                return
            }

            do {
                let value = try JSONSerialization.jsonObject(with: data)
                if let json = value as? [String: Any] {
                    DispatchQueue.main.async {
                        guard self?.requestGeneration == generation, self?.isEnabled == true else { return }
                        if self?.parseWeatherResponse(json) == true {
                            self?.lastFetchTime = Date()
                            self?.lastUpdated = Date()
                            if let city = self?.selectedCity { self?.weather.locationName = city.label }
                            self?.hasWeatherData = true
                        } else {
                            self?.errorMessage = L10n.text("Weather update failed. Try again.")
                        }
                    }
                } else { throw URLError(.cannotParseResponse) }
            } catch {
                DispatchQueue.main.async {
                    guard self?.requestGeneration == generation, self?.isEnabled == true else { return }
                    self?.errorMessage = L10n.text("Weather update failed. Try again.")
                }
            }
        }
        weatherTask?.resume()

        // Fetch AQI from Open-Meteo Air Quality API
        let aqiURLString = "https://air-quality-api.open-meteo.com/v1/air-quality?latitude=\(latitude)&longitude=\(longitude)&current=us_aqi"
        if let aqiURL = URL(string: aqiURLString) {
            airQualityTask = session.dataTask(with: URLRequest(url: aqiURL, timeoutInterval: 20)) { [weak self] data, response, error in
                guard let data, error == nil, let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { return }
                do {
                    if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let current = json["current"] as? [String: Any],
                       let aqi = current["us_aqi"] as? Int, aqi >= 0 {
                        DispatchQueue.main.async {
                            guard self?.requestGeneration == generation, self?.isEnabled == true else { return }
                            self?.weather.aqi = aqi
                        }
                    }
                } catch {
                    print("AQI parse error: \(error)")
                }
            }
            airQualityTask?.resume()
        }

        // Reverse geocode for location name
        guard selectedCity == nil else { return }
        let location = CLLocation(latitude: latitude, longitude: longitude)
        guard let request = makeReverseGeocodingRequest(location) else { return }
        geocodingRequest = request
        request.start { [weak self] city in
            guard let self, self.requestGeneration == generation, self.isEnabled, self.selectedCity == nil else { return }
            self.geocodingRequest = nil
            if let city { self.weather.locationName = city }
        }
    }

    private func cancelReverseGeocoding() {
        geocodingRequest?.cancel()
        geocodingRequest = nil
    }

    // MARK: - Parsing

    @discardableResult
    func parseWeatherResponse(_ json: [String: Any], now: Date = Date()) -> Bool {
        guard let current = json["current"] as? [String: Any],
              let temperature = current["temperature_2m"] as? Double, temperature.isFinite,
              current["weather_code"] is Int,
              let feelsLike = current["apparent_temperature"] as? Double, feelsLike.isFinite,
              current["relative_humidity_2m"] is Int,
              let wind = current["wind_speed_10m"] as? Double, wind.isFinite,
              let daily = json["daily"] as? [String: Any],
              let high = (daily["temperature_2m_max"] as? [Double])?.first, high.isFinite,
              let low = (daily["temperature_2m_min"] as? [Double])?.first, low.isFinite,
              let uv = (daily["uv_index_max"] as? [Double])?.first, uv.isFinite,
              let hourly = json["hourly"] as? [String: Any],
              let times = hourly["time"] as? [String],
              let temperatures = hourly["temperature_2m"] as? [Double], temperatures.allSatisfy(\.isFinite),
              let codes = hourly["weather_code"] as? [Int],
              times.count == temperatures.count, times.count == codes.count else { return false }
        // Current weather
        if let current = json["current"] as? [String: Any] {
            if let temp = current["temperature_2m"] as? Double {
                weather.temperature = temp
            }
            if let code = current["weather_code"] as? Int {
                weather.conditionCode = code
                weather.conditionIcon = conditionIcon(for: code)
                if current["is_day"] as? Int == 0 {
                    if code == 0 { weather.conditionIcon = "moon.stars.fill" }
                    if code == 1 || code == 2 { weather.conditionIcon = "cloud.moon.fill" }
                }
            }
            if let feelsLike = current["apparent_temperature"] as? Double {
                weather.feelsLike = feelsLike
            }
            if let humidity = current["relative_humidity_2m"] as? Int {
                weather.humidity = humidity
            }
            if let wind = current["wind_speed_10m"] as? Double {
                weather.windSpeed = wind
            }
        }

        // Daily high/low + UV
        if let daily = json["daily"] as? [String: Any] {
            if let maxTemps = daily["temperature_2m_max"] as? [Double], let first = maxTemps.first {
                weather.temperatureHigh = first
            }
            if let minTemps = daily["temperature_2m_min"] as? [Double], let first = minTemps.first {
                weather.temperatureLow = first
            }
            if let uvMax = daily["uv_index_max"] as? [Double], let first = uvMax.first {
                weather.uvIndex = first
            }
        }

        // Hourly forecast (next 6 hours)
        if let hourly = json["hourly"] as? [String: Any],
           let times = hourly["time"] as? [String],
           let temps = hourly["temperature_2m"] as? [Double],
           let codes = hourly["weather_code"] as? [Int] {

            let parser = DateFormatter()
            parser.locale = Locale(identifier: "en_US_POSIX")
            parser.timeZone = (json["timezone"] as? String).flatMap(TimeZone.init(identifier:)) ?? .current
            parser.dateFormat = "yyyy-MM-dd'T'HH:mm"
            let days = hourly["is_day"] as? [Int] ?? []
            let rain = hourly["precipitation_probability"] as? [Int?] ?? []

            var forecast: [HourlyWeather] = []
            for i in 0..<min(times.count, temps.count, codes.count) {
                guard let date = parser.date(from: times[i]), date.addingTimeInterval(3600) > now else { continue }
                var icon = conditionIcon(for: codes[i])
                if i < days.count, days[i] == 0 {
                    if codes[i] == 0 { icon = "moon.stars.fill" }
                    if codes[i] == 1 || codes[i] == 2 { icon = "cloud.moon.fill" }
                }

                forecast.append(HourlyWeather(
                    id: date,
                    timeZone: parser.timeZone,
                    temperature: temps[i],
                    conditionIcon: icon,
                    precipitationProbability: i < rain.count ? rain[i].map { min(100, max(0, $0)) } : nil
                ))
                if forecast.count == 6 { break }
            }
            weather.hourlyForecast = forecast
            weather.precipitationProbability = forecast.first?.precipitationProbability
        }
        hasWeatherData = true
        return true
    }

    // MARK: - WMO Weather Code Mapping

    private func conditionIcon(for code: Int) -> String {
        switch code {
        case 0: return "sun.max.fill"
        case 1, 2: return "cloud.sun.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51, 53, 55: return "cloud.drizzle.fill"
        case 61, 63, 65: return "cloud.rain.fill"
        case 56, 57, 66, 67: return "cloud.sleet.fill"
        case 71, 73, 75, 77: return "cloud.snow.fill"
        case 80, 81, 82: return "cloud.heavyrain.fill"
        case 85, 86: return "cloud.snow.fill"
        case 95, 96, 99: return "cloud.bolt.fill"
        default: return "sun.max.fill"
        }
    }

    // MARK: - Refresh

    var locationStatusDescription: String {
        if let city = selectedCity { return L10n.format("Manual city: %@", city.label) }
        switch authorizationStatus {
        case .authorizedAlways: return L10n.text("Location access allowed. Using your current location.")
        case .denied, .restricted: return L10n.text("Location access unavailable. Choose a city or open System Settings.")
        default: return L10n.text("Allow location access or choose a city manually.")
        }
    }

    func isStale(at now: Date) -> Bool {
        guard let lastUpdated else { return false }
        return now.timeIntervalSince(lastUpdated) > 3600
    }

    func selectCity(_ city: WeatherCity?) {
        guard city == nil || city?.isValid == true else { return }
        requestGeneration = UUID()
        weatherTask?.cancel(); airQualityTask?.cancel()
        weatherTask = nil; airQualityTask = nil
        cancelReverseGeocoding()
        locationManager.stopUpdatingLocation()
        cancelCitySearch()
        selectedCity = city
        if let city, let data = try? JSONEncoder().encode(city) { preferenceStore.set(data, forKey: WeatherCity.defaultsKey) }
        else { preferenceStore.removeObject(forKey: WeatherCity.defaultsKey) }
        weather = WeatherData()
        hasWeatherData = false
        lastFetchTime = nil; lastUpdated = nil
        isLoading = false; errorMessage = nil
        if isEnabled { requestLocationAndFetch() }
    }

    func cancelCitySearch() {
        citySearchID = UUID()
        citySearchTask?.cancel()
        citySearchTask = nil
        cityResults = []
        isSearchingCities = false
    }

    func searchCities(_ text: String) {
        cancelCitySearch()
        guard isEnabled else { return }
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { citySearchError = L10n.text("Enter at least two characters."); return }
        citySearchError = nil
        isSearchingCities = true
        let id = citySearchID
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [URLQueryItem(name: "name", value: query), URLQueryItem(name: "count", value: "8"),
                                 URLQueryItem(name: "language", value: L10n.languageCode == "zh-Hans" ? "zh" : "en")]
        let url = components.url!
        citySearchTask = Task { @MainActor [weak self, session] in
            do {
                let (data, response) = try await session.data(for: URLRequest(url: url, timeoutInterval: 15))
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
                struct Results: Decodable { let results: [WeatherCity]? }
                let cities = try JSONDecoder().decode(Results.self, from: data).results ?? []
                guard let self, self.isEnabled, self.citySearchID == id, !Task.isCancelled else { return }
                self.cityResults = cities.filter(\.isValid)
                self.isSearchingCities = false
                self.citySearchTask = nil
                if self.cityResults.isEmpty { self.citySearchError = L10n.text("No matching cities.") }
            } catch {
                guard let self, self.isEnabled, self.citySearchID == id, !Task.isCancelled else { return }
                self.citySearchError = L10n.text("City search failed. Try again.")
                self.isSearchingCities = false
                self.citySearchTask = nil
            }
        }
    }

    private func registerRefresh() {
        let generation = lifecycleGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isEnabled, self.lifecycleGeneration == generation,
                  self.refreshToken == nil, let scheduler = self.scheduler() else { return }
            self.refreshToken = scheduler.register(
                id: "weather.refresh",
                name: "Weather refresh",
                module: .builtIn(.weather),
                policy: .visibleOnly(Constants.weatherRefreshInterval, tolerance: 300),
                enabled: { [weak self] in self?.isEnabled == true }
            ) { [weak self] in
                self?.refreshIfAuthorized()
            }
        }
    }

    deinit {
        weatherTask?.cancel()
        airQualityTask?.cancel()
        citySearchTask?.cancel()
        geocodingRequest?.cancel()
        let token = refreshToken
        let scheduler = scheduler
        Task { @MainActor in
            scheduler()?.unregister(token)
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension WeatherManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        guard selectedCity == nil else { return }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            refreshIfAuthorized()
        default:
            requestGeneration = UUID()
            weatherTask?.cancel()
            airQualityTask?.cancel()
            weatherTask = nil
            airQualityTask = nil
            cancelReverseGeocoding()
            manager.stopUpdatingLocation()
            isLoading = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard isEnabled, selectedCity == nil, let location = locations.last, location.horizontalAccuracy >= 0 else { return }
        manager.stopUpdatingLocation()
        fetchWeather(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard isEnabled else { return }
        isLoading = false
        errorMessage = L10n.text("Location unavailable. Try again.")
    }
}
