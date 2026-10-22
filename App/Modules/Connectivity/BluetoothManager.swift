import Foundation
import IOBluetooth
import Combine

struct BluetoothDeviceInfo: Identifiable {
    let id: String
    let name: String
    let isConnected: Bool
    let deviceType: BluetoothDeviceType
    let batteryLevel: Int?

    enum BluetoothDeviceType {
        case airpods
        case headphones
        case speaker
        case keyboard
        case mouse
        case trackpad
        case other

        var iconName: String {
            switch self {
            case .airpods: return "airpodspro"
            case .headphones: return "headphones"
            case .speaker: return "hifispeaker.fill"
            case .keyboard: return "keyboard"
            case .mouse: return "magicmouse"
            case .trackpad: return "rectangle.and.hand.point.up.left"
            case .other: return "wave.3.right.circle.fill"
            }
        }
    }
}

@MainActor
final class BluetoothManager: ObservableObject {
    static let shared = BluetoothManager()
    var onConnectionChanged: ((String, Bool) -> Void)?

    @Published var connectedDevices: [BluetoothDeviceInfo] = []
    @Published private(set) var knownDevices: [BluetoothDeviceInfo] = []
    @Published var lastConnectedDevice: BluetoothDeviceInfo?
    @Published var lastDisconnectedDeviceName: String?

    private var refreshToken: ModuleRefreshToken?
    private var isEnabled = false
    private var lifecycleGeneration = UUID()
    private var connectionNotification: IOBluetoothUserNotification?
    private var disconnectionNotifications: [String: IOBluetoothUserNotification] = [:]

    private init() {}

    // MARK: - Monitoring

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        lifecycleGeneration = UUID()
        if enabled {
            updateDevices()
            startMonitoring()
        } else {
            onConnectionChanged = nil
            connectionNotification?.unregister()
            connectionNotification = nil
            disconnectionNotifications.values.forEach { $0.unregister() }
            disconnectionNotifications.removeAll()
            connectedDevices = []
            knownDevices = []
            lastConnectedDevice = nil
            lastDisconnectedDeviceName = nil
            ModuleRefreshScheduler.shared.unregister(refreshToken)
            refreshToken = nil
        }
    }

    private func startMonitoring() {
        guard isEnabled, PermissionsManager.shared.checkBluetooth() else { return }
        // Register for Bluetooth connection notifications
        connectionNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))

        refreshToken = ModuleRefreshScheduler.shared.register(
            id: "connectivity.bluetooth",
            name: "Bluetooth fallback refresh",
            module: .builtIn(.connectivity),
            policy: .visibleOnly(60, tolerance: 15),
            enabled: { [weak self] in self?.isEnabled == true }
        ) { [weak self] in
            self?.updateDevices()
        }
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let generation = lifecycleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
            self.updateDevices()
            if let name = device.name {
                let info = BluetoothDeviceInfo(
                    id: device.addressString ?? UUID().uuidString,
                    name: name,
                    isConnected: true,
                    deviceType: Self.classifyDevice(device),
                    batteryLevel: nil
                )
                self.lastConnectedDevice = info
                self.lastDisconnectedDeviceName = nil
                self.onConnectionChanged?(info.id, true)
            }
        }

    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let generation = lifecycleGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
            self.lastDisconnectedDeviceName = device.name
            self.lastConnectedDevice = nil
            self.updateDevices()
            if let id = device.addressString { self.onConnectionChanged?(id, false) }
        }
    }

    // MARK: - Device Updates

    func updateDevices() {
        guard isEnabled else { return }
        guard PermissionsManager.shared.checkBluetooth(), let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            knownDevices = []
            connectedDevices = []
            lastConnectedDevice = nil
            disconnectionNotifications.values.forEach { $0.unregister() }
            disconnectionNotifications.removeAll()
            return
        }
        let connected = paired.filter { $0.isConnected() }
        knownDevices = paired.compactMap { device in
            guard let name = device.name, let id = device.addressString else { return nil }
            return BluetoothDeviceInfo(id: id, name: name, isConnected: device.isConnected(), deviceType: Self.classifyDevice(device), batteryLevel: nil)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let connectedIDs = Set(connected.compactMap(\.addressString))
        for id in Array(disconnectionNotifications.keys) where !connectedIDs.contains(id) {
            disconnectionNotifications.removeValue(forKey: id)?.unregister()
        }
        for device in connected {
            guard let id = device.addressString, disconnectionNotifications[id] == nil else { continue }
            disconnectionNotifications[id] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        }

        let devices = paired.filter { $0.isConnected() }.compactMap { device -> BluetoothDeviceInfo? in
            guard let name = device.name else { return nil }
            return BluetoothDeviceInfo(
                id: device.addressString ?? UUID().uuidString,
                name: name,
                isConnected: true,
                deviceType: Self.classifyDevice(device),
                batteryLevel: nil
            )
        }

        let generation = lifecycleGeneration
        DispatchQueue.main.async {
            guard self.isEnabled, self.lifecycleGeneration == generation else { return }
            self.connectedDevices = devices
            if let latest = self.lastConnectedDevice, !devices.contains(where: { $0.id == latest.id }) {
                self.lastConnectedDevice = nil
            }
        }
    }

    // MARK: - Device Classification

    private static func classifyDevice(_ device: IOBluetoothDevice) -> BluetoothDeviceInfo.BluetoothDeviceType {
        let name = (device.name ?? "").lowercased()

        if name.contains("airpod") { return .airpods }
        if name.contains("headphone") || name.contains("beats") { return .headphones }
        if name.contains("speaker") || name.contains("homepod") { return .speaker }
        if name.contains("keyboard") { return .keyboard }
        if name.contains("mouse") { return .mouse }
        if name.contains("trackpad") { return .trackpad }

        // Classify by device class
        let deviceClass = device.deviceClassMajor
        switch deviceClass {
        case 4: return .headphones // Audio
        case 5: return .keyboard // Peripheral
        default: return .other
        }
    }

    deinit {
        connectionNotification?.unregister()
        disconnectionNotifications.values.forEach { $0.unregister() }
        let token = refreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(token)
        }
    }
}
