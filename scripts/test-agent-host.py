#!/usr/bin/env python3
"""Execute production manager lifecycle and compact selection without macOS UI.

Run: python3 scripts/test-agent-host.py (requires a Swift compiler).
For native SwiftUI compilation and XCTest, run bash scripts/test-native.sh on macOS.
These portable checks execute selection policy, not the rendered macOS UI.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
files = ['App/Modules/Agent/AgentModels.swift', 'App/Modules/Agent/AgentHookWire.swift',
         'App/Modules/Agent/CodexPrimaryChannel.swift',
         'App/Modules/Agent/CodexAgentState.swift', 'App/Modules/Agent/AgentSessionStore.swift',
         'App/Modules/Agent/AgentStatusSource.swift', 'App/Modules/Agent/AgentManager.swift',
         'App/Application/CompactModuleSelection.swift']
production = '\n'.join('\n'.join(line for line in (ROOT / name).read_text().splitlines()
                              if not line.startswith('import ')) for name in files)
app_state = (ROOT / 'App/Application/AppState.swift').read_text()
compact_host_selection = app_state[
    app_state.index('    var compactPresentationModule: ActiveModule? {'):
    app_state.index('    var shouldUseMinimalCompactLayout: Bool {')]
stubs = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
enum ModuleType { case agent, nowPlaying, shelf, teleprompter, battery, weather, notifications, volumeHUD, connectivity, tools }
enum ActiveModule: Equatable { case builtIn(ModuleType) }
enum IslandState { case compact, expanded, fullExpanded }
struct IdleContent { var module: ModuleType? = .battery }
struct PresentationPreferences { var idleContent = IdleContent() }
@MainActor final class NowPlayingManager {
    static let shared = NowPlayingManager()
    var title = ""
    var albumArt: String?
    var sourceName = ""
    var isPlaying = false
    var isEligibleForCompactPresentation: Bool { isPlaying }
}
@MainActor final class AppState {
    static let shared = AppState()
    let objectWillChange = Change()
    final class Change { func send() {} }
    var activeModule: ActiveModule?
    var explicitlySelectedModule: ActiveModule?
    var presentationHoldModule: ActiveModule?
    var nowPlayingEnabled = true
    var compactMusicEnabled = true
    var batteryEnabled = true
    var agentEnabled = false
    var toolsEnabled = true
    var isKeepAwakeActive = false
    var currentState = IslandState.compact
    var presentationPreferences = PresentationPreferences()
    func isModuleEnabled(_ module: ModuleType) -> Bool { module != .battery || batteryEnabled }
    __COMPACT_HOST_SELECTION__
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    var opened: [URL] = []
    var hasHandler = true
    func urlForApplication(toOpen url: URL) -> URL? { hasHandler ? URL(fileURLWithPath: "/Applications/Test.app") : nil }
    @discardableResult func open(_ url: URL) -> Bool { opened.append(url); return true }
}
@MainActor final class CodexLiveStatusSource: AgentStatusSource {
    func start(receive: @escaping @MainActor (AgentSourceUpdate) -> Void) {}
    func stop() {}
}
@MainActor final class Source: AgentStatusSource {
    var callback: (@MainActor (AgentSourceUpdate) -> Void)?
    var starts = 0
    var stops = 0
    func start(receive: @escaping @MainActor (AgentSourceUpdate) -> Void) {
        starts += 1
        callback = receive
        receive(.connection(.connected))
    }
    func stop() { stops += 1 }
}
'''
stubs = stubs.replace('    __COMPACT_HOST_SELECTION__', compact_host_selection)
checks = r'''
@main struct Checks {
    @MainActor static func main() {
        let source = Source()
        var creations = 0
        var handlerID = "com.openai.codex"
        let manager = AgentManager(sourceFactory: { creations += 1; return source }, handlerBundleIdentifier: { _ in handlerID })
        precondition(creations == 0 && manager.groups.isEmpty)
        manager.setEnabled(true)
        manager.setEnabled(true)
        precondition(creations == 1 && source.starts == 1)
        let id = AgentSessionID(providerID: "verified-test", sessionID: "thread-1")
        let event = AgentSessionEvent(id: id, runID: "run", requestID: nil,
            eventID: "event", sequence: 1, parentID: nil, classification: .userSession,
            status: .waitingInput, title: "Test fixture", summary: nil, updatedAt: Date())
        source.callback?(.event(event))
        precondition(manager.groups.count == 1 && manager.attentionCount == 1)
        let target = AgentVerifiedNavigationTarget(desktopThreadID: "thread-1")
        source.callback?(.navigation(id, target))
        manager.openSession(id)
        precondition(NSWorkspace.shared.opened.count == 1)
        NSWorkspace.shared.hasHandler = false
        precondition(!manager.canOpenSession(id))
        manager.openSession(id)
        precondition(NSWorkspace.shared.opened.count == 1)
        NSWorkspace.shared.hasHandler = true
        handlerID = "untrusted.other.application"
        precondition(!manager.canOpenSession(id))
        manager.openSession(id)
        precondition(NSWorkspace.shared.opened.count == 1)
        handlerID = "com.openai.codex"
        precondition(AgentVerifiedNavigationTarget(desktopThreadID: "../invented?x").url == nil)
        let oldCallback = source.callback
        manager.setEnabled(false)
        precondition(source.stops == 1 && manager.groups.isEmpty && manager.attentionCount == 0)
        precondition(manager.navigationTargets.isEmpty)
        oldCallback?(.event(event))
        manager.openSession(id)
        precondition(manager.groups.isEmpty && NSWorkspace.shared.opened.count == 1)
        manager.setEnabled(true)
        oldCallback?(.connection(.connected))
        oldCallback?(.event(event))
        precondition(manager.groups.isEmpty && source.starts == 2)
        source.callback?(.event(event))
        precondition(manager.groups.count == 1)
        source.callback?(.navigation(id, target))
        source.callback?(.retainingSessions([]))
        precondition(manager.groups.isEmpty && manager.navigationTargets.isEmpty && manager.attentionCount == 0)
        source.callback?(.event(event))
        precondition(manager.groups.count == 1)
        source.callback?(.connection(.permissionDenied))
        precondition(manager.groups.isEmpty && manager.attentionCount == 0)
        source.callback?(.event(event))
        precondition(manager.groups.isEmpty)
        manager.setEnabled(false)
        precondition(source.stops == 2)

        func resolve(_ active: ActiveModule? = nil, explicit: ActiveModule? = nil,
                     hold: ActiveModule? = nil, attention: Bool = false,
                     media: Bool = false, playing: Bool = false,
                     batteryEnabled: Bool = true, compact: Bool = true, runningAgent: Bool = false) -> ActiveModule? {
            CompactModuleSelection.resolve(active: active, explicitSelection: explicit,
                presentationHold: hold, hasVerifiedAgentAttention: attention, hasMedia: media,
                mediaIsPlaying: playing, batteryEnabled: batteryEnabled, isCompact: compact,
                hasVerifiedAgentActivity: runningAgent)
        }
        precondition(resolve(media: true) == .builtIn(.battery))
        precondition(resolve(media: true, playing: true) == .builtIn(.nowPlaying))
        precondition(resolve(attention: true, media: true, playing: true) == .builtIn(.agent))
        precondition(resolve(runningAgent: true) == .builtIn(.agent))
        precondition(resolve(media: true, playing: true, runningAgent: true) == .builtIn(.nowPlaying))
        precondition(resolve(hold: .builtIn(.shelf), runningAgent: true) == .builtIn(.shelf))
        precondition(resolve(explicit: .builtIn(.shelf), media: true, playing: true) == .builtIn(.nowPlaying))
        precondition(resolve(explicit: .builtIn(.shelf), attention: true, compact: false) == .builtIn(.shelf))
        precondition(resolve(explicit: .builtIn(.shelf), hold: .builtIn(.teleprompter), attention: true, media: true, playing: true) == .builtIn(.teleprompter))
        precondition(resolve() == .builtIn(.battery))
        precondition(resolve(batteryEnabled: false) == nil)
        precondition(resolve(media: true, batteryEnabled: false) == nil)
        precondition(resolve(media: true, playing: true, batteryEnabled: false) == .builtIn(.nowPlaying))
        for module in [ModuleType.weather, .notifications, .connectivity, .volumeHUD, .battery, .shelf, .nowPlaying] {
            precondition(resolve(.builtIn(module), media: true) == .builtIn(.battery))
            precondition(resolve(.builtIn(module), media: true, playing: true) == .builtIn(.nowPlaying))
            precondition(resolve(.builtIn(module), media: true, compact: false) == .builtIn(module))
        }
        precondition(resolve(.builtIn(.volumeHUD), media: true, playing: true, compact: false) == .builtIn(.volumeHUD))

        // Exercise the production AppState wiring as well as the pure selector.
        // A nil selection must stay empty in CompactView, including all-off idle.
        let host = AppState()
        let media = NowPlayingManager.shared
        precondition(host.compactPresentationModule == .builtIn(.battery))
        host.batteryEnabled = false
        precondition(host.compactPresentationModule == nil)
        host.nowPlayingEnabled = false
        media.title = "Retained disabled metadata"
        media.albumArt = "Retained art"
        media.sourceName = "Disabled source"
        media.isPlaying = true
        precondition(host.compactPresentationModule == nil)
        host.batteryEnabled = true
        precondition(host.compactPresentationModule == .builtIn(.battery))
        host.nowPlayingEnabled = true
        host.batteryEnabled = false
        media.title = "" // Retained artwork/source alone cannot turn paused media into activity.
        media.isPlaying = false
        precondition(host.compactPresentationModule == nil)
        host.activeModule = .builtIn(.shelf)
        precondition(host.compactPresentationModule == nil)
        host.activeModule = .builtIn(.battery)
        host.batteryEnabled = true
        precondition(host.compactPresentationModule == .builtIn(.battery))
        media.isPlaying = true
        precondition(host.compactPresentationModule == .builtIn(.nowPlaying))
        host.activeModule = nil
        media.albumArt = nil
        media.sourceName = ""
        precondition(host.compactPresentationModule == .builtIn(.battery))
        host.batteryEnabled = false
        precondition(host.compactPresentationModule == nil)
        print("PASS: production Agent lifecycle, lazy source, cancellation generation, source health, verified navigation, compact priorities and enabled idle fallback")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notchx-agent-host-') as directory:
    source = Path(directory) / 'Checks.swift'
    binary = Path(directory) / 'Checks'
    source.write_text(stubs + production + checks)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-swift-version', '5', '-parse-as-library',
                    '-module-cache-path', str(Path(directory) / 'cache'), str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
