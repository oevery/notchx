import Foundation

/// Compiled-in manager activation. Presentation and refresh cancellation remain
/// owned by the host rather than a plugin runtime.
@MainActor
final class NativeModuleRegistry {
    static let modules = ModuleType.allCases
    private var activatedModules: Set<ModuleType> = []
    private var activatedBluetooth = false

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
            switch module {
            case .nowPlaying:
                NowPlayingManager.shared.setEnabled(true)
            case .volumeHUD:
                VolumeManager.shared.setEnabled(true)
            case .battery:
                BatteryManager.shared.setEnabled(true)
            case .shelf:
                ShelfStore.shared.setEnabled(true)
            case .connectivity:
                WiFiManager.shared.setEnabled(true)
                if PermissionsManager.shared.check(.bluetooth) == true {
                    BluetoothManager.shared.setEnabled(true)
                    activatedBluetooth = true
                } else if activatedBluetooth {
                    BluetoothManager.shared.setEnabled(false)
                    activatedBluetooth = false
                }
            case .calendar:
                // Keep user intent enabled while CalendarManager gates work on permission.
                CalendarManager.shared.setEnabled(true)
                if refreshPermissions { CalendarManager.shared.refreshAccessStatus() }
            case .weather:
                WeatherManager.shared.setEnabled(true)
            case .notifications:
                NotificationManager.shared.setEnabled(true)
            case .teleprompter:
                TeleprompterManager.shared.setEnabled(true)
            case .agent:
                AgentManager.shared.setEnabled(true)
            case .tools:
                ToolsManager.shared.setEnabled(true)
            }
            activatedModules.insert(module)
        }
    }

    func shutdown() {
        for module in activatedModules { deactivate(module) }
        activatedModules.removeAll()
    }

    @discardableResult
    private func deactivate(_ module: ModuleType) -> Bool {
        switch module {
        case .connectivity:
            WiFiManager.shared.setEnabled(false)
            if activatedBluetooth {
                BluetoothManager.shared.setEnabled(false)
                activatedBluetooth = false
            }
        case .calendar:
            CalendarManager.shared.setEnabled(false)
        case .weather:
            WeatherManager.shared.setEnabled(false)
        case .notifications:
            NotificationManager.shared.setEnabled(false)
        case .teleprompter:
            TeleprompterManager.shared.setEnabled(false)
        case .agent:
            AgentManager.shared.setEnabled(false)
        case .tools:
            return ToolsManager.shared.setEnabled(false)
        case .nowPlaying:
            NowPlayingManager.shared.setEnabled(false)
        case .battery:
            BatteryManager.shared.setEnabled(false)
        case .volumeHUD:
            VolumeManager.shared.setEnabled(false)
        case .shelf:
            ShelfStore.shared.setEnabled(false)
        }
        return true
    }
}
