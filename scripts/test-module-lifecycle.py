#!/usr/bin/env python3
"""Run production registry and Shelf cancellation primitives with portable test doubles.

This executes Swift control flow, not AppKit/EventKit/IOKit integration. Use the
native macOS test/build scripts for SDK typechecking and OS runtime validation.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
registry = (ROOT / 'App/Application/NativeModuleRegistry.swift').read_text()
shelf = (ROOT / 'App/Modules/Shelf/ShelfStore.swift').read_text()
primitives = shelf[shelf.index('private final class ShelfDropSession'):shelf.index('@MainActor\nfinal class ShelfStore')]
managers = ['NowPlaying', 'Volume', 'Battery', 'Shelf', 'WiFi', 'Bluetooth', 'Calendar', 'Weather', 'Notification', 'Teleprompter', 'Agent', 'Tools']
stubs = '''
import Foundation

enum ModuleType: CaseIterable { case nowPlaying, volumeHUD, battery, shelf, connectivity, calendar, weather, notifications, teleprompter, agent, tools }
@MainActor final class AppState {
    var enabled = Set(ModuleType.allCases)
    var reconciliations = 0
    func reconcileEnabledModules() { reconciliations += 1 }
    func isModuleEnabled(_ module: ModuleType) -> Bool { enabled.contains(module) }
    func setModuleEnabled(_ module: ModuleType, enabled value: Bool) {
        if value { enabled.insert(module) } else { enabled.remove(module) }
    }
}
@MainActor final class PermissionsManager {
    static let shared = PermissionsManager()
    enum Permission { case bluetooth }
    var bluetooth = true
    func check(_ permission: Permission) -> Bool { bluetooth }
}
@MainActor class Manager {
    var enabled = false
    var transitions = 0
    var permissionRefreshes = 0
    var stopSucceeds = true
    @discardableResult func setEnabled(_ value: Bool) -> Bool {
        guard enabled != value else { return true }
        guard value || stopSucceeds else { return false }
        enabled = value
        transitions += 1
        return true
    }
    func refreshAccessStatus() { permissionRefreshes += 1 }
}
'''
for name in managers:
    cls = 'ShelfStore' if name == 'Shelf' else name + 'Manager'
    stubs += f'@MainActor final class {cls}: Manager {{ static let shared = {cls}() }}\n'
checks = '''
@main struct LifecycleChecks {
    @MainActor static func main() async {
        let state = AppState()
        let registry = NativeModuleRegistry()
        let managers: [ModuleType: Manager] = [
            .nowPlaying: NowPlayingManager.shared, .volumeHUD: VolumeManager.shared,
            .battery: BatteryManager.shared, .shelf: ShelfStore.shared,
            .connectivity: WiFiManager.shared, .calendar: CalendarManager.shared,
            .weather: WeatherManager.shared, .notifications: NotificationManager.shared,
            .teleprompter: TeleprompterManager.shared, .agent: AgentManager.shared, .tools: ToolsManager.shared
        ]
        registry.activateEnabledModules(in: state)
        precondition(managers.values.allSatisfy { $0.enabled })
        precondition(BluetoothManager.shared.enabled)
        for disabled in ModuleType.allCases {
            state.enabled.remove(disabled)
            registry.activateEnabledModules(in: state)
            for (module, manager) in managers {
                precondition(manager.enabled == (module != disabled), "Disabled wrong module")
            }
            precondition(BluetoothManager.shared.enabled == (disabled != .connectivity))
            state.enabled.insert(disabled)
            registry.activateEnabledModules(in: state)
        }
        let transitions = managers.mapValues { $0.transitions }
        registry.activateEnabledModules(in: state)
        for (module, manager) in managers { precondition(manager.transitions == transitions[module]) }
        precondition(CalendarManager.shared.permissionRefreshes == 0)
        registry.activateEnabledModules(in: state, refreshPermissions: true)
        precondition(CalendarManager.shared.permissionRefreshes == 1)
        PermissionsManager.shared.bluetooth = false
        registry.activateEnabledModules(in: state)
        precondition(!BluetoothManager.shared.enabled && WiFiManager.shared.enabled)
        ToolsManager.shared.stopSucceeds = false
        state.enabled.remove(.tools)
        registry.activateEnabledModules(in: state)
        precondition(state.enabled.contains(.tools) && ToolsManager.shared.enabled, "Failed shutdown lost the module and retry path")
        ToolsManager.shared.stopSucceeds = true
        state.enabled.remove(.tools)
        registry.activateEnabledModules(in: state)
        precondition(!ToolsManager.shared.enabled)
        registry.shutdown()
        precondition(managers.values.allSatisfy { !$0.enabled })
        state.enabled.removeAll()
        registry.activateEnabledModules(in: state)
        precondition(managers.values.allSatisfy { !$0.enabled })
        registry.shutdown()

        let session = ShelfDropSession()
        let progress = Progress(totalUnitCount: 1)
        session.track(progress)
        var cancelled = 0
        session.onCancel { cancelled += 1 }
        precondition(session.withActive { 42 } == 42)
        session.cancel()
        session.cancel()
        precondition(cancelled == 1 && progress.isCancelled && !session.isActive)
        precondition(session.withActive { 99 } == nil)
        let lateProgress = Progress(totalUnitCount: 1)
        session.track(lateProgress)
        precondition(lateProgress.isCancelled)
        session.onCancel { cancelled += 1 }
        precondition(cancelled == 2)

        let files = FileManager.default
        let storage = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let existing = storage.appendingPathComponent("existing.png")
        let bucket = storage.appendingPathComponent(UUID().uuidString)
        let incoming = bucket.appendingPathComponent("new.png")
        try! files.createDirectory(at: bucket, withIntermediateDirectories: true)
        try! Data([1]).write(to: existing)
        let fileSession = ShelfDropSession()
        precondition(fileSession.withCreatedFile {
            try! Data([2]).write(to: incoming)
            return incoming
        } == incoming)
        fileSession.cancel()
        precondition(!files.fileExists(atPath: incoming.path))
        precondition(!files.fileExists(atPath: bucket.path))
        precondition(files.fileExists(atPath: existing.path))
        try! files.removeItem(at: storage)

        let waitSession = ShelfDropSession()
        let value: Int? = await withCheckedContinuation { continuation in
            let request = ShelfDropRequest(continuation)
            waitSession.onCancel { request.finish(nil) }
            waitSession.cancel()
            request.finish(123) // late provider callback must not resume twice
        }
        precondition(value == nil)
        print("PASS: production registry independently disables all " + String(ModuleType.allCases.count) + " modules; reconciliation, permission refresh, shutdown, Shelf cancellation and late callbacks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notchx-lifecycle-') as directory:
    source = Path(directory) / 'LifecycleChecks.swift'
    binary = Path(directory) / 'LifecycleChecks'
    source.write_text(stubs + registry + primitives + checks)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-module-cache-path', str(Path(directory) / 'module-cache'), '-swift-version', '5', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

teleprompter = (ROOT / 'App/Modules/Teleprompter/TeleprompterManager.swift').read_text()
teleprompter = '\n'.join(line for line in teleprompter.splitlines() if not line.startswith('import '))
teleprompter_reading = (ROOT / 'App/Modules/Teleprompter/TeleprompterReading.swift').read_text()
# Keep first-launch and restore defaults from the production mapping in this harness.
settings = (ROOT / 'App/Settings/SettingsRestore.swift').read_text()
setting_default = settings[settings.index('struct SettingDefault<Value: Sendable>'):settings.index('enum SettingsDefaults')]
restore_entry = settings[settings.index('struct SettingsRestoreEntry'):settings.index('enum SettingsRestoreScope')]
teleprompter_defaults = settings[settings.index('    enum Teleprompter {'):settings.index('\n}\n\nstruct SettingsRestoreEntry')]
production_defaults = setting_default + restore_entry + 'enum SettingsDefaults {\n' + teleprompter_defaults + '\n}\n'
teleprompter_stubs = '''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
enum TextAlignment { case leading, center, trailing }
enum L10n {
    static func text(_ value: String) -> String { value }
    static func format(_ value: String, _ argument: Double) -> String { String(format: value, argument) }
}
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func string(forKey key: String) -> String? { values[key] as? String }
    func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    func object(forKey key: String) -> Any? { values[key] }
    func data(forKey key: String) -> Data? { values[key] as? Data }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
enum SFSpeechRecognizer { static func supportedLocales() -> Set<Locale> { [Locale(identifier: "en-US")] } }
enum TeleprompterShortcutModifiers: String { case controlOption, controlCommand, optionCommand }
@MainActor protocol TeleprompterShortcutControlling {
    func apply(enabled: Bool, modifiers: TeleprompterShortcutModifiers, action: @escaping (TeleprompterKeyboardAction) -> Void) -> Bool
}
@MainActor final class TeleprompterGlobalShortcuts: TeleprompterShortcutControlling {
    func apply(enabled: Bool, modifiers: TeleprompterShortcutModifiers, action: @escaping (TeleprompterKeyboardAction) -> Void) -> Bool { true }
}
enum TeleprompterTextTokenizer { static func displayText(from value: String) -> String { value } }
final class TeleprompterSpeechRecognizer {
    var onTerminalFailure: (@MainActor () -> Void)?
    var error: String?
    var isListening = false
    var recognizedCharCount = 0
    var stops = 0
    func start(with text: String, localeIdentifier: String, resuming: Bool = false) { isListening = true }
    func stop() { isListening = false; stops += 1 }
    func reset() { stop() }
    func preparePosition(in text: String, localeIdentifier: String, displayOffset: Int) { stop(); recognizedCharCount = displayOffset }
}
@MainActor final class PermissionsManager {
    static let shared = PermissionsManager()
    var requests = 0
    func checkMicrophone() -> Bool { true }
    func checkSpeechRecognition() -> Bool { true }
    func requestTeleprompterWordTrackingAccess() { requests += 1 }
}
enum ModuleType { case teleprompter }
enum ActiveModule { case builtIn(ModuleType) }
enum Tab { case module(ActiveModule) }
enum Presentation { case fullExpanded, compact }
@MainActor final class AppState {
    static let shared = AppState()
    var teleprompterEnabled = true
    var currentState = Presentation.compact
    var holds = 0
    func holdPresentation(for module: ActiveModule) { holds += 1 }
    func selectFullExpandedTab(_ tab: Tab) {}
    func presentFullExpandedModule(_ module: ModuleType) { currentState = .fullExpanded }
    func cancelFullExpandedDismiss() {}
    func showHUD(module: ActiveModule, autoDismiss: Bool) {}
    func cancelAutoDismiss() {}
    func releasePresentationHold(for module: ActiveModule) { holds = max(0, holds - 1) }
}
'''
teleprompter_checks = r'''
@main struct TeleprompterChecks {
    @MainActor static func main() {
        let manager = TeleprompterManager.shared
        manager.setScript("Preserve this script")
        manager.play()
        precondition(!manager.isPlaying && !manager.isCountingDown)
        precondition(AppState.shared.holds == 0)
        manager.setEnabled(true)
        manager.play()
        precondition(manager.countdownValue == 3)
        precondition(AppState.shared.holds == 1)
        manager.play()
        precondition(manager.countdownValue == 3 && AppState.shared.holds == 1, "Repeated play bypassed countdown")
        manager.pause()
        manager.play()
        precondition(manager.countdownValue == 3, "Interrupted countdown was skipped")
        manager.setScript("Edited during countdown")
        precondition(!manager.isCountingDown && !manager.isPlaying && AppState.shared.holds == 0)
        manager.setScript("Preserve this script")
        manager.setEnabled(false)
        precondition(!manager.isPlaying && !manager.isCountingDown)
        precondition(AppState.shared.holds == 0 && !manager.speechRecognizer.isListening)
        precondition(manager.scriptText == "Preserve this script")
        manager.play()
        precondition(!manager.isCountingDown && !manager.isPlaying)
        manager.setEnabled(true)
        manager.play()
        precondition(manager.countdownValue == 3)
        manager.pause()
        manager.listeningMode = .wordTracking
        manager.play()
        manager.setEnabled(false)
        precondition(!manager.isPlaying && !manager.speechRecognizer.isListening)
        precondition(manager.scriptText == "Preserve this script")
        let permissionRequests = PermissionsManager.shared.requests
        UserDefaults.standard.set(SettingsDefaults.Teleprompter.listeningMode.value, forKey: SettingsDefaults.Teleprompter.listeningMode.key)
        UserDefaults.standard.set(SettingsDefaults.Teleprompter.scrollSpeed.value, forKey: SettingsDefaults.Teleprompter.scrollSpeed.key)
        UserDefaults.standard.set(SettingsDefaults.Teleprompter.fontSize.value, forKey: SettingsDefaults.Teleprompter.fontSize.key)
        UserDefaults.standard.set(SettingsDefaults.Teleprompter.alignment.value, forKey: SettingsDefaults.Teleprompter.alignment.key)
        UserDefaults.standard.removeObject(forKey: SettingsDefaults.Teleprompter.speechLocaleKey)
        manager.reloadRestoredPreferences()
        precondition(manager.listeningMode == .classic && manager.scrollSpeed == 7 && manager.fontSize == 22 && manager.textAlignmentIndex == 1)
        precondition(manager.scriptText == "Preserve this script")
        precondition(UserDefaults.standard.object(forKey: SettingsDefaults.Teleprompter.speechLocaleKey) == nil)
        precondition(PermissionsManager.shared.requests == permissionRequests)
        manager.play()
        precondition(!manager.isPlaying && !manager.isCountingDown && !manager.speechRecognizer.isListening)
        manager.setEnabled(true)
        manager.setScript("First paragraph\n\n第二段内容\nFinal paragraph")
        manager.countdownSeconds = 0
        manager.play()
        precondition(manager.isPlaying && !manager.isCountingDown, "Zero countdown did not start immediately")
        manager.reportProgress(0.25)
        precondition(manager.readingProgress == 0.25)
        manager.jumpToParagraph(manager.paragraphs[1].id)
        precondition(!manager.isPlaying && !manager.speechRecognizer.isListening)
        precondition(manager.seekRequest.displayOffset == manager.paragraphs[1].id)
        // Scroll distance need not be proportional to character count. Arrows
        // follow the paragraph actually at the reading guide.
        manager.reportProgress(0.99, paragraphOffset: manager.paragraphs[0].id)
        manager.perform(.nextParagraph)
        precondition(manager.seekRequest.displayOffset == manager.paragraphs[1].id)
        manager.perform(.nextParagraph)
        precondition(manager.seekRequest.displayOffset == manager.paragraphs[2].id)
        manager.perform(.previousParagraph)
        precondition(manager.seekRequest.displayOffset == manager.paragraphs[1].id)
        manager.perform(.slower)
        precondition(manager.scrollSpeed == 6)
        manager.countdownSeconds = 2
        manager.play()
        precondition(manager.countdownValue == 2)
        manager.setEnabled(false)
        precondition(!manager.isCountingDown && AppState.shared.holds == 0)
        print("PASS: production teleprompter lifecycle and restored defaults keep disabled state/script, pause playback, preserve automatic language, and request no permissions")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notchx-teleprompter-') as directory:
    source = Path(directory) / 'TeleprompterChecks.swift'
    binary = Path(directory) / 'TeleprompterChecks'
    session_store = (ROOT / 'App/Modules/Teleprompter/TeleprompterSessionStore.swift').read_text().replace('import Combine\n', '')
    session_store = 'final class ObservableObjectPublisher { func send() {} }\n' + session_store
    source.write_text(teleprompter_stubs + production_defaults + teleprompter_reading + session_store + teleprompter + teleprompter_checks)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-module-cache-path', str(Path(directory) / 'module-cache'), '-swift-version', '5', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)

# Compile the production scheduler; only the host and SwiftUI observation are doubles.
scheduler = (ROOT / 'App/Utilities/ModuleRefreshScheduler.swift').read_text()
scheduler = scheduler.replace("import SwiftUI\n", "")
scheduler_stubs = r'''
public protocol ObservableObject: AnyObject {}
@propertyWrapper public struct Published<Value> {
    public var wrappedValue: Value
    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
import Foundation
enum IslandState { case compact, expanded, fullExpanded }
enum ActiveModule: Equatable { case test; var displayName: String { "Test" } }
enum FullExpandedTab: Equatable { case home, module(ActiveModule) }
@MainActor final class AppState {
    static let shared = AppState()
    var effectiveEnergyMode: EnergyMode = .normal
    func isModuleVisibleForRefresh(_ module: ActiveModule) -> Bool { true }
    func isModuleVisibleForRefresh(_ module: ActiveModule, state: IslandActivityState) -> Bool { true }
}
@MainActor final class EnergySuggestionPresenter {
    enum Reason { case sustainedActivity }
    static let shared = EnergySuggestionPresenter()
    func suggestLowPower(reason: Reason) {}
}
@main struct Check {
    @MainActor static func main() {
        let scheduler = ModuleRefreshScheduler(isolatedForTesting: true)
        var runs = 0
        let old = scheduler.register(id: "x", name: "old", policy: .interval(60, tolerance: 1), action: {})
        let replacement = scheduler.register(id: "x", name: "new", policy: .interval(60, tolerance: 1)) { runs += 1 }
        scheduler.unregister(old)
        scheduler.runNow(id: "x")
        precondition(runs == 1 && scheduler.jobCountForTesting == 1)
        scheduler.unregister(replacement)
        precondition(scheduler.jobCountForTesting == 0 && scheduler.scheduledTimerCountForTesting == 0)
        scheduler.register(id: "x", name: "self removal", policy: .interval(60, tolerance: 1)) { scheduler.unregister(id: "x") }
        scheduler.runNow(id: "x")
        precondition(scheduler.jobCountForTesting == 0 && scheduler.scheduledTimerCountForTesting == 0)
        scheduler.register(id: "x", name: "shutdown", policy: .interval(60, tolerance: 1)) { scheduler.shutdown() }
        scheduler.runNow(id: "x")
        precondition(scheduler.jobCountForTesting == 0 && scheduler.scheduledTimerCountForTesting == 0)
        var enabled = true
        scheduler.register(id: "x", name: "disable", policy: .interval(60, tolerance: 1), enabled: { enabled }) {
            enabled = false
            scheduler.refreshScheduling()
        }
        scheduler.runNow(id: "x")
        precondition(scheduler.scheduledTimerCountForTesting == 0)
        precondition(scheduler.diagnostics.first?.status == "Disabled")
        scheduler.shutdown()

        var energyMode = EnergyMode.normal
        let energyScheduler = ModuleRefreshScheduler(isolatedForTesting: true, energyModeProvider: { energyMode })
        let state = IslandActivityState(islandState: .compact, activeModule: nil,
                                        fullExpandedTab: .home, isHovering: false, isAppActive: true)
        energyScheduler.register(id: "energy", name: "Energy", policy: .interval(5, tolerance: 1), action: {})
        let normalDeadline = energyScheduler.diagnostics.first!.nextFireDate!
        energyScheduler.updateActivityState(state)
        precondition(energyScheduler.diagnostics.first!.nextFireDate == normalDeadline)
        energyMode = .lowPower
        energyScheduler.updateActivityState(state)
        let lowPowerDeadline = energyScheduler.diagnostics.first!.nextFireDate!
        precondition(lowPowerDeadline.timeIntervalSince(normalDeadline) > 50)
        energyScheduler.updateActivityState(state)
        precondition(energyScheduler.diagnostics.first!.nextFireDate == lowPowerDeadline)
        energyMode = .normal
        energyScheduler.updateActivityState(state)
        let restoredDeadline = energyScheduler.diagnostics.first!.nextFireDate!
        precondition(restoredDeadline.timeIntervalSince(lowPowerDeadline) < -50)
        energyScheduler.updateActivityState(state)
        precondition(energyScheduler.diagnostics.first!.nextFireDate == restoredDeadline)
        precondition(energyScheduler.scheduledTimerCountForTesting == 1)
        energyMode = .lowPower
        energyScheduler.refreshScheduling()
        let explicitRefreshDeadline = energyScheduler.diagnostics.first!.nextFireDate!
        energyScheduler.updateActivityState(state)
        precondition(energyScheduler.diagnostics.first!.nextFireDate == explicitRefreshDeadline)
        energyScheduler.shutdown()
        print("PASS: production scheduler stale token, self-removal, shutdown, reentrant disable, energy transitions and unchanged deadline preservation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notchx-scheduler-') as directory:
    source = Path(directory) / 'SchedulerChecks.swift'
    binary = Path(directory) / 'SchedulerChecks'
    source.write_text(scheduler_stubs + scheduler)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-module-cache-path', str(Path(directory) / 'module-cache'), '-DDEBUG', '-swift-version', '5', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
