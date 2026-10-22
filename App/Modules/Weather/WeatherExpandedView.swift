import SwiftUI

struct WeatherExpandedView: View {
    @ObservedObject private var manager = WeatherManager.shared
    @ObservedObject var preferences: WeatherPreferences
    @EnvironmentObject var appState: AppState
    @Environment(\.islandPresentationState) private var presentationState

    private func temp(_ celsius: Double) -> String {
        preferences.temperatureUnit.formatted(celsius)
    }

    var body: some View {
        Group {
            if manager.hasWeatherData {
                forecast
            } else {
                HStack(spacing: 12) {
                    if manager.isLoading { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(manager.isLoading ? L10n.text("Fetching weather") : L10n.text("Weather unavailable"))
                        Text(manager.errorMessage ?? L10n.text("Allow location access to fetch local weather."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.text("Retry")) { manager.requestLocationAndFetch() }
                        .disabled(manager.isLoading)
                }
            }
        }
    }

    private var forecast: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                WeatherFreshnessView(manager: manager)
                Spacer()
                if (presentationState ?? appState.currentState) == .fullExpanded {
                    Button(L10n.text("Refresh")) { manager.requestLocationAndFetch() }
                        .disabled(manager.isLoading).accessibilityIdentifier("weather-refresh")
                }
            }
            if let error = manager.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("Retry")) { manager.requestLocationAndFetch() }
                        .disabled(manager.isLoading)
                }
            }
            // Current weather
            HStack(spacing: 12) {
                Image(systemName: manager.weather.conditionIcon)
                    .font(.system(size: 28))
                    .foregroundColor(.white)

                VStack(alignment: .leading, spacing: 2) {
                    Text(temp(manager.weather.temperature))
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundColor(.white)

                    Text(manager.weather.condition)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("H:\(temp(manager.weather.temperatureHigh))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                    Text("L:\(temp(manager.weather.temperatureLow))")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            // Location
            if !manager.weather.locationName.isEmpty {
                Text(manager.weather.locationName)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }

            if (presentationState ?? appState.currentState) == .fullExpanded {
                Divider().background(.white.opacity(0.2))

                // Hourly forecast + details side by side
                HStack(alignment: .top, spacing: 0) {
                    // Hourly forecast (left)
                    if !manager.weather.hourlyForecast.isEmpty {
                        StableScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 16) {
                                ForEach(manager.weather.hourlyForecast) { hour in
                                    VStack(spacing: 4) {
                                        Text(hour.hour)
                                            .font(.system(size: 10))
                                            .foregroundColor(.white.opacity(0.6))

                                        Image(systemName: hour.conditionIcon)
                                            .font(.system(size: 14))
                                            .foregroundColor(.white)

                                        Text(temp(hour.temperature))
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(.white)
                                    }
                                }
                            }
                        }
                    }

                    Spacer(minLength: 16)

                    // Weather details grid (right)
                    weatherDetailsGrid
                }
            }
        }
    }

    private var weatherDetailsGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                weatherDetailCell(icon: "thermometer.medium", title: "Feels Like", value: temp(manager.weather.feelsLike))
                weatherDetailCell(icon: "humidity.fill", title: "Humidity", value: "\(manager.weather.humidity)%")
                weatherDetailCell(icon: "aqi.medium", title: "AQI", value: aqiLabel)
            }
            HStack(spacing: 16) {
                weatherDetailCell(icon: "wind", title: "Wind", value: preferences.windUnit.formatted(milesPerHour: manager.weather.windSpeed))
                weatherDetailCell(icon: "drop", title: "Rain chance", value: manager.weather.precipitationProbability.map { "\($0)%" } ?? "—")
                weatherDetailCell(icon: "sun.max.trianglebadge.exclamationmark.fill", title: "UV Index", value: uvLabel)
                Spacer()
            }
        }
    }

    private func weatherDetailCell(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 16, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text(title))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
                Text(value)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
        }
    }

    private var uvLabel: String {
        let uv = manager.weather.uvIndex
        let level: String
        switch uv {
        case ..<3: level = L10n.text("Low")
        case ..<6: level = L10n.text("Mod")
        case ..<8: level = L10n.text("High")
        case ..<11: level = L10n.text("Very High")
        default: level = L10n.text("Extreme")
        }
        return "\(Int(uv)) \(level)"
    }

    private var aqiLabel: String {
        guard let aqi = manager.weather.aqi else { return "—" }
        let level: String
        switch aqi {
        case ..<51: level = L10n.text("Good")
        case ..<101: level = L10n.text("Moderate")
        case ..<151: level = L10n.text("Unhealthy*")
        case ..<201: level = L10n.text("Unhealthy")
        case ..<301: level = L10n.text("Very Poor")
        default: level = L10n.text("Hazardous")
        }
        return "\(aqi) \(level)"
    }
}
