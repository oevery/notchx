import Foundation

struct WeatherCity: Codable, Equatable, Identifiable {
    let name: String
    let latitude: Double
    let longitude: Double
    var country: String? = nil
    var id: String { "\(latitude),\(longitude)" }
    var label: String { [name, country].compactMap { $0 }.joined(separator: ", ") }
    var isValid: Bool { !name.isEmpty && latitude.isFinite && longitude.isFinite && (-90...90).contains(latitude) && (-180...180).contains(longitude) }
    static let defaultsKey = "weather.selectedCity"
}

enum WeatherWindUnit: String, CaseIterable, Identifiable {
    case automatic, kilometersPerHour, metersPerSecond, milesPerHour
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return L10n.text("Follow System")
        case .kilometersPerHour: return "km/h"
        case .metersPerSecond: return "m/s"
        case .milesPerHour: return "mph"
        }
    }
    func formatted(milesPerHour value: Double, locale: Locale = .current) -> String {
        let unit = self == .automatic ? (locale.region?.identifier == "US" ? Self.milesPerHour : .kilometersPerHour) : self
        let converted: Double
        switch unit {
        case .kilometersPerHour: converted = value * 1.609344
        case .metersPerSecond: converted = value * 0.44704
        default: converted = value
        }
        return String(format: "%.1f %@", locale: L10n.locale, converted, unit.title)
    }
}
