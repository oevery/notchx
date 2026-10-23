import XCTest
@testable import NotchX

@MainActor
final class NativeModuleRegistryTests: XCTestCase {
    func testEveryModuleDisablesIndependentlyAndFailedStopPreservesRetry() {
        let domain = "app.notchx.tests.registry.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: preferences)
        // Independent expected identities: never derive this oracle from the
        // registry's routing implementation.
        let expected: [ModuleType: any NativeModuleManaging.Type] = [
            .nowPlaying: NowPlayingManager.self, .volumeHUD: VolumeManager.self,
            .battery: BatteryManager.self, .shelf: ShelfStore.self,
            .connectivity: WiFiManager.self, .calendar: CalendarManager.self,
            .weather: WeatherManager.self, .notifications: NotificationManager.self,
            .teleprompter: TeleprompterManager.self, .agent: AgentManager.self,
            .tools: ToolsManager.self
        ]
        XCTAssertEqual(Set(expected.keys), Set(ModuleType.allCases))
        let bluetoothID = ObjectIdentifier(BluetoothManager.self)
        let toolsID = ObjectIdentifier(ToolsManager.self)
        func expectedRunning(excluding module: ModuleType? = nil) -> Set<ObjectIdentifier> {
            var result = Set(expected.filter { $0.key != module }.values.map { ObjectIdentifier($0) })
            if module != .connectivity { result.insert(bluetoothID) }
            return result
        }
        var running: Set<ObjectIdentifier> = []
        var permission = true, canStopTools = true
        var transitions = 0, refreshes = 0
        let registry = NativeModuleRegistry(updateManager: { managerType, enabled in
            let manager = ObjectIdentifier(managerType)
            if manager == toolsID && !enabled && !canStopTools { return false }
            if running.contains(manager) != enabled { transitions += 1 }
            if enabled { running.insert(manager) } else { running.remove(manager) }
            return true
        }, bluetoothAllowed: { permission },
           refreshCalendarAccess: { refreshes += 1 })
        for module in ModuleType.allCases { state.setModuleEnabled(module, enabled: true) }
        registry.activateEnabledModules(in: state)
        XCTAssertEqual(running, expectedRunning())
        XCTAssertTrue(running.contains(bluetoothID))
        for disabled in ModuleType.allCases {
            state.setModuleEnabled(disabled, enabled: false)
            registry.activateEnabledModules(in: state)
            XCTAssertEqual(running, expectedRunning(excluding: disabled))
            XCTAssertEqual(running.contains(bluetoothID), disabled != .connectivity)
            state.setModuleEnabled(disabled, enabled: true)
            registry.activateEnabledModules(in: state)
        }
        let unchanged = transitions
        registry.activateEnabledModules(in: state)
        XCTAssertEqual(transitions, unchanged)
        XCTAssertEqual(refreshes, 0)
        registry.activateEnabledModules(in: state, refreshPermissions: true)
        XCTAssertEqual(refreshes, 1)
        permission = false
        registry.activateEnabledModules(in: state)
        XCTAssertFalse(running.contains(bluetoothID))
        XCTAssertTrue(running.contains(ObjectIdentifier(WiFiManager.self)))
        canStopTools = false
        state.setModuleEnabled(.tools, enabled: false)
        registry.activateEnabledModules(in: state)
        XCTAssertTrue(state.isModuleEnabled(.tools))
        XCTAssertTrue(running.contains(toolsID))
        canStopTools = true
        state.setModuleEnabled(.tools, enabled: false)
        registry.activateEnabledModules(in: state)
        XCTAssertFalse(running.contains(toolsID))
        registry.shutdown()
        XCTAssertTrue(running.isEmpty)
        for module in ModuleType.allCases { state.setModuleEnabled(module, enabled: false) }
        registry.activateEnabledModules(in: state)
        registry.shutdown()
        XCTAssertTrue(running.isEmpty)
    }
}
