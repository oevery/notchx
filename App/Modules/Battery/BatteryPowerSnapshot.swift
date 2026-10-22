import Foundation

struct BatteryPowerSnapshot: Equatable {
    let level: Int
    let charging: Bool
    let pluggedIn: Bool
    var status: String {
        if !pluggedIn { return L10n.text("Battery") }
        if level >= 100 { return L10n.text("Fully charged") }
        return charging ? L10n.text("Charging") : L10n.text("Connected, not charging")
    }
    func event(after previous: Self?, lowThreshold: Int) -> IslandEventKind? {
        guard let previous else { return nil }
        if !pluggedIn, level <= lowThreshold, previous.level > lowThreshold { return .lowBattery }
        if pluggedIn, level >= 100, previous.level < 100 { return .batteryFull }
        if pluggedIn != previous.pluggedIn || charging != previous.charging { return .powerChanged }
        return nil
    }
}
