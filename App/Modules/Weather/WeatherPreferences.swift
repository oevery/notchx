import Foundation
import Combine

enum TemperatureUnit: String {
    case celsius, fahrenheit

    func formatted(_ celsius: Double, showsUnit: Bool = true) -> String {
        guard celsius.isFinite else { return "—" }
        let value = self == .celsius ? celsius : celsius * 9 / 5 + 32
        guard value.isFinite else { return "—" }
        let suffix = showsUnit ? (self == .celsius ? "°C" : "°F") : "°"
        let rounded = value.rounded()
        return String(format: "%.0f", rounded == 0 ? 0 : rounded) + suffix
    }
}

enum WeatherCondition {
    static func name(for code: Int) -> String {
        let key: String
        switch code {
        case 1, 2, 3: key = "Partly Cloudy"
        case 45, 48: key = "Foggy"
        case 51, 53, 55: key = "Drizzle"
        case 61, 63, 65: key = "Rain"
        case 56, 57, 66, 67: key = "Freezing Rain"
        case 71, 73, 75: key = "Snow"
        case 77: key = "Snow Grains"
        case 80, 81, 82: key = "Showers"
        case 85, 86: key = "Snow Showers"
        case 95: key = "Thunderstorm"
        case 96, 99: key = "Hailstorm"
        default: key = "Clear Sky"
        }
        return L10n.text(key)
    }
}

/// Weather's preference authority exists independently of its network/location runtime.
final class WeatherPreferences: ObservableObject {
    static let shared = WeatherPreferences()
    private let defaults: UserDefaults
    @Published var temperatureUnit: TemperatureUnit {
        didSet { defaults.set(temperatureUnit.rawValue, forKey: SettingsDefaults.Weather.temperatureUnit.key) }
    }
    @Published var windUnit: WeatherWindUnit {
        didSet { defaults.set(windUnit.rawValue, forKey: SettingsDefaults.Weather.windUnit.key) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        temperatureUnit = TemperatureUnit(rawValue: SettingsDefaults.Weather.temperatureUnit.read(from: defaults)) ?? .celsius
        windUnit = WeatherWindUnit(rawValue: SettingsDefaults.Weather.windUnit.read(from: defaults)) ?? .automatic
    }

    func reload() {
        temperatureUnit = TemperatureUnit(rawValue: SettingsDefaults.Weather.temperatureUnit.read(from: defaults)) ?? .celsius
        windUnit = WeatherWindUnit(rawValue: SettingsDefaults.Weather.windUnit.read(from: defaults)) ?? .automatic
    }
}
