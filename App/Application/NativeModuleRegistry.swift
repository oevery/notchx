import Foundation

/// A metatype identifies the actual manager without constructing its shared
/// instance. Tests replace only invocation, after the production routing switch.
@MainActor
protocol NativeModuleManaging: AnyObject {
    static func setNativeModuleEnabled(_ enabled: Bool) -> Bool
}

@MainActor
private protocol SharedNativeModuleManaging: NativeModuleManaging {
    static var shared: Self { get }
    func setEnabled(_ enabled: Bool)
}

extension SharedNativeModuleManaging {
    static func setNativeModuleEnabled(_ enabled: Bool) -> Bool {
        shared.setEnabled(enabled)
        return true
    }
}

extension NowPlayingManager: SharedNativeModuleManaging {}
extension VolumeManager: SharedNativeModuleManaging {}
extension BatteryManager: SharedNativeModuleManaging {}
extension ShelfStore: SharedNativeModuleManaging {}
extension WiFiManager: SharedNativeModuleManaging {}
extension BluetoothManager: SharedNativeModuleManaging {}
extension CalendarManager: SharedNativeModuleManaging {}
extension WeatherManager: SharedNativeModuleManaging {}
extension NotificationManager: SharedNativeModuleManaging {}
extension TeleprompterManager: SharedNativeModuleManaging {}
extension AgentManager: SharedNativeModuleManaging {}
extension ToolsManager: NativeModuleManaging {
    static func setNativeModuleEnabled(_ enabled: Bool) -> Bool {
        shared.setEnabled(enabled)
    }
}

/// Compiled-in manager activation. Device/service side effects are supplied by
/// the host; registry selection and failed-disable recovery stay here.
@MainActor
final class NativeModuleRegistry {
    static let modules = ModuleType.allCases
    private var activatedModules: Set<ModuleType> = []
    private var activatedBluetooth = false
    private let updateManager: (any NativeModuleManaging.Type, Bool) -> Bool
    private let bluetoothAllowed: () -> Bool
    private let refreshCalendarAccess: () -> Void

    init(updateManager: ((any NativeModuleManaging.Type, Bool) -> Bool)? = nil,
         bluetoothAllowed: (() -> Bool)? = nil,
         refreshCalendarAccess: (() -> Void)? = nil) {
        self.updateManager = updateManager ?? { $0.setNativeModuleEnabled($1) }
        self.bluetoothAllowed = bluetoothAllowed ?? { PermissionsManager.shared.check(.bluetooth) == true }
        self.refreshCalendarAccess = refreshCalendarAccess ?? { CalendarManager.shared.refreshAccessStatus() }
    }

    func activateEnabledModules(in state: AppState, refreshPermissions: Bool = false,
                                configure: (ModuleType) -> Void = { _ in }) {
        state.reconcileEnabledModules()
        for module in Self.modules {
            guard state.isModuleEnabled(module) else {
                if activatedModules.contains(module) {
                    if deactivate(module) { activatedModules.remove(module) }
                    else { state.setModuleEnabled(module, enabled: true) }
                }
                continue
            }
            configure(module)
            _ = setEnabled(module, true)
            if module == .connectivity {
                if bluetoothAllowed() {
                    _ = updateManager(BluetoothManager.self, true)
                    activatedBluetooth = true
                } else if activatedBluetooth {
                    _ = updateManager(BluetoothManager.self, false)
                    activatedBluetooth = false
                }
            }
            if module == .calendar && refreshPermissions { refreshCalendarAccess() }
            activatedModules.insert(module)
        }
    }

    func shutdown() {
        for module in activatedModules { deactivate(module) }
        activatedModules.removeAll()
    }

    @discardableResult
    private func deactivate(_ module: ModuleType) -> Bool {
        let stopped = setEnabled(module, false)
        if module == .connectivity && activatedBluetooth {
            _ = updateManager(BluetoothManager.self, false)
            activatedBluetooth = false
        }
        return stopped
    }

    private func setEnabled(_ module: ModuleType, _ enabled: Bool) -> Bool {
        switch module {
        case .nowPlaying: return updateManager(NowPlayingManager.self, enabled)
        case .volumeHUD: return updateManager(VolumeManager.self, enabled)
        case .battery: return updateManager(BatteryManager.self, enabled)
        case .shelf: return updateManager(ShelfStore.self, enabled)
        case .connectivity: return updateManager(WiFiManager.self, enabled)
        case .calendar: return updateManager(CalendarManager.self, enabled)
        case .weather: return updateManager(WeatherManager.self, enabled)
        case .notifications: return updateManager(NotificationManager.self, enabled)
        case .teleprompter: return updateManager(TeleprompterManager.self, enabled)
        case .agent: return updateManager(AgentManager.self, enabled)
        case .tools: return updateManager(ToolsManager.self, enabled)
        }
    }
}
