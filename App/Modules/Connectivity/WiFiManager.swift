import Foundation
import CoreWLAN
import Combine

@MainActor
final class WiFiManager: ObservableObject {
    static let shared = WiFiManager()

    @Published var ssid: String?
    @Published var signalStrength: Int = 0
    @Published var isConnected: Bool = false

    private let client = CWWiFiClient.shared()
    private var refreshToken: ModuleRefreshToken?
    private var isEnabled = false
    private var lifecycleGeneration = UUID()

    private init() {}

    // MARK: - Monitoring

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        lifecycleGeneration = UUID()
        if enabled {
            updateWiFiInfo()
            startMonitoring()
        } else {
            try? client.stopMonitoringAllEvents()
            client.delegate = nil
            let token = refreshToken
            refreshToken = nil
            ModuleRefreshScheduler.shared.unregister(token)
            ssid = nil
            isConnected = false
            signalStrength = 0
        }
    }

    private func startMonitoring() {
        client.delegate = self
        // Register for Wi-Fi events
        do {
            try client.startMonitoringEvent(with: .ssidDidChange)
            try client.startMonitoringEvent(with: .linkDidChange)
        } catch {
            print("WiFi monitoring error: \(error)")
        }

        let generation = lifecycleGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isEnabled, self.lifecycleGeneration == generation, self.refreshToken == nil else { return }
            self.refreshToken = ModuleRefreshScheduler.shared.register(
                id: "connectivity.wifi",
                name: "Wi-Fi fallback refresh",
                module: .builtIn(.connectivity),
                policy: .visibleOnly(30, tolerance: 10),
                enabled: { [weak self] in self?.isEnabled == true }
            ) { [weak self] in
                self?.updateWiFiInfo()
            }
        }
    }

    // MARK: - Updates

    func updateWiFiInfo() {
        guard isEnabled else { return }
        let generation = lifecycleGeneration
        guard let interface = client.interface() else {
            DispatchQueue.main.async {
                guard self.isEnabled, self.lifecycleGeneration == generation else { return }
                self.ssid = nil
                self.isConnected = false
                self.signalStrength = 0
            }
            return
        }

        DispatchQueue.main.async {
            guard self.isEnabled, self.lifecycleGeneration == generation else { return }
            let name = interface.ssid()
            // SSID can be redacted without Location permission. The active PHY
            // remains available; zero denotes kCWPHYModeNone.
            let connected = interface.powerOn() && (name != nil || interface.activePHYMode().rawValue != 0)
            self.ssid = connected ? name : nil
            self.isConnected = connected
            self.signalStrength = connected ? interface.rssiValue() : 0
        }
    }

    // MARK: - Helpers

    var signalIconName: String {
        if !isConnected { return "wifi.slash" }
        let rssi = signalStrength
        if rssi == 0 { return "wifi" }
        if rssi > -50 { return "wifi" }
        if rssi > -60 { return "wifi" }
        if rssi > -70 { return "wifi" }
        return "wifi.exclamationmark"
    }

    var signalDescription: String {
        guard isConnected else { return L10n.text("Not connected") }
        let rssi = signalStrength
        if rssi == 0 { return L10n.text("Signal unavailable") }
        if rssi > -50 { return L10n.text("Excellent signal") }
        if rssi > -60 { return L10n.text("Strong signal") }
        if rssi > -70 { return L10n.text("Fair signal") }
        return L10n.text("Weak signal")
    }

    deinit {
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
        let token = refreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(token)
        }
    }
}

extension WiFiManager: CWEventDelegate {
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.updateWiFiInfo() }
    }

    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        Task { @MainActor [weak self] in self?.updateWiFiInfo() }
    }
}
