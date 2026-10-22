import SwiftUI

struct WeatherCompactView: View {
    @ObservedObject private var manager = WeatherManager.shared
    @ObservedObject var preferences: WeatherPreferences

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: manager.hasWeatherData ? manager.weather.conditionIcon : "cloud")
                .font(.system(size: 12))
                .foregroundColor(.white)

            Text(manager.hasWeatherData ? preferences.temperatureUnit.formatted(manager.weather.temperature) : "—")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
        }
    }

}
