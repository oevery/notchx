import XCTest
import SwiftUI
import AppKit
@testable import NotchX

@MainActor
final class IslandMotionTests: XCTestCase {
    func testInitialMountCannotReleaseAnotherScreensActiveMotion() {
        withState { state in
            var settled = 0
            state.surfaceMotionSettled = { settled += 1 }
            let owner = UUID(), token = state.beginSurfaceMotion(owner: owner)
            state.settleInitialSurface()
            XCTAssertEqual(settled, 0)
            XCTAssertTrue(state.isSurfaceMotionActive)
            state.finishSurfaceMotion(owner: owner, token: token)
            XCTAssertEqual(settled, 1)
            state.settleInitialSurface()
            XCTAssertEqual(settled, 2)
        }
    }

    func testActualWindowPreservesOldHeightDuringContentCollapseAndRepeatedTargets() async throws {
        let domain = "app.notchx.tests.height-motion." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "module.agent.enabled")
        let state = AppState(preferenceStore: defaults)
        state.isHovering = true
        state.presentFullExpandedModule(.agent)
        let controller = IslandWindowController(appState: state, pointerSource: {
            IslandPointerSnapshot(location: NSPoint(x: NSScreen.main!.frame.midX, y: NSScreen.main!.frame.maxY))
        })
        controller.showIsland()
        let window = try XCTUnwrap(controller.windows.first)
        defer {
            controller.hideIsland(); controller.windows.forEach { $0.contentView = nil; $0.close() }
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            defaults.removePersistentDomain(forName: domain)
        }
        await waitUntil { !state.isSurfaceMotionActive && !state.suppressDismissScheduling }
        state.updateAgentPanelContentHeight(400)
        await waitUntil { !state.isSurfaceMotionActive && window.frame.size == state.windowSize }
        let expanded = window.frame.size
        let gate = UUID(), held = state.beginSurfaceMotion(owner: gate)
        state.updateAgentPanelContentHeight(150)
        await NativeUI.drainMainQueue()
        for _ in 0..<8 {
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(window.frame.height, expanded.height, "The old shell must fit until the current transition finishes")
            XCTAssertTrue(state.isSurfaceMotionActive)
            try await Task.sleep(for: .milliseconds(10))
        }
        state.updateAgentPanelContentHeight(250)
        await NativeUI.drainMainQueue()
        XCTAssertGreaterThanOrEqual(window.frame.height, expanded.height)
        state.finishSurfaceMotion(owner: gate, token: held)
        await waitUntil { !state.isSurfaceMotionActive && window.frame.size == state.windowSize }
        XCTAssertLessThan(window.frame.height, expanded.height)
        XCTAssertFalse(state.suppressDismissScheduling)
    }

    func testShortPlaybackInterruptionDoesNotExtendOrResurrectGrace() {
        let now = Date(timeIntervalSince1970: 100)
        var grace = CompactPlaybackGrace()
        grace.update(wasPlaying: true, isPlaying: false, enabled: true, at: now)
        XCTAssertTrue(grace.isActive(at: now.addingTimeInterval(0.3)))
        grace.update(wasPlaying: false, isPlaying: false, enabled: true, at: now.addingTimeInterval(0.4))
        XCTAssertFalse(grace.isActive(at: now.addingTimeInterval(0.7)))
        grace.update(wasPlaying: false, isPlaying: true, enabled: true, at: now)
        XCTAssertNil(grace.deadline)
        grace.update(wasPlaying: true, isPlaying: false, enabled: false, at: now)
        XCTAssertNil(grace.deadline)
    }

    func testPauseRetentionUsesOriginalPauseTimeAndStaysSeparateFromLoadingGrace() {
        let now = Date(timeIntervalSince1970: 100)
        var retention = PausedPlaybackRetention()
        retention.update(isPlaying: false, enabled: true, at: now)
        retention.update(isPlaying: false, enabled: true, at: now.addingTimeInterval(4))
        XCTAssertFalse(retention.isActive(seconds: 0, at: now))
        XCTAssertTrue(retention.isActive(seconds: 5, at: now.addingTimeInterval(4)))
        XCTAssertFalse(retention.isActive(seconds: 5, at: now.addingTimeInterval(5)))
        XCTAssertTrue(retention.isActive(seconds: 15, at: now.addingTimeInterval(6)))
        XCTAssertFalse(retention.isActive(seconds: 15, at: now.addingTimeInterval(15)))
        XCTAssertTrue(retention.isActive(seconds: -1, at: now.addingTimeInterval(1000)))
        retention.update(isPlaying: true, enabled: true, at: now.addingTimeInterval(20))
        XCTAssertFalse(retention.isActive(seconds: 15, at: now.addingTimeInterval(20)))
        retention.update(isPlaying: false, enabled: true, at: now.addingTimeInterval(21))
        XCTAssertTrue(retention.isActive(seconds: 5, at: now.addingTimeInterval(25)))
        retention.update(isPlaying: false, enabled: false, at: now.addingTimeInterval(26))
        XCTAssertFalse(retention.isActive(seconds: 5, at: now.addingTimeInterval(26)))
    }

    func testMusicOpensInOneSurfaceTransition() {
        withState { state in
            var transitions: [(IslandState, IslandState)] = []
            state.didChangeState = { transitions.append(($0, $1)) }
            state.presentNowPlaying()
            XCTAssertEqual(transitions.count, 1)
            XCTAssertEqual(transitions.first?.0, .compact)
            XCTAssertEqual(transitions.first?.1, .fullExpanded)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.nowPlaying)))
        }
    }

    func testCompletionNotifiesWindowOnlyAfterLatestTransitionOnAllScreens() {
        withState { state in
            var finishes = 0
            state.surfaceMotionSettled = { finishes += 1 }
            let a = UUID(), b = UUID()
            let old = state.beginSurfaceMotion(owner: a)
            let latest = state.beginSurfaceMotion(owner: a)
            let second = state.beginSurfaceMotion(owner: b)
            state.finishSurfaceMotion(owner: a, token: old)
            state.finishSurfaceMotion(owner: b, token: second)
            XCTAssertEqual(finishes, 0)
            XCTAssertTrue(state.isSurfaceMotionActive)
            state.finishSurfaceMotion(owner: a, token: latest)
            XCTAssertEqual(finishes, 1)
            let disconnected = state.beginSurfaceMotion(owner: b)
            state.removeSurfaceMotion(owner: b)
            XCTAssertEqual(finishes, 2)
            state.finishSurfaceMotion(owner: b, token: disconnected)
            XCTAssertEqual(finishes, 2)
        }
    }

    func testWindowPreparationDoesNotRunInsideTransactionRegistration() async {
        let domain = "app.notchx.tests.motion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        defer { defaults.removePersistentDomain(forName: domain) }
        let prepared = expectation(description: "Window preparation leaves the render stack")
        var registering = true
        state.surfaceMotionBegan = {
            XCTAssertFalse(registering)
            prepared.fulfill()
        }
        let owner = UUID()
        let token = state.beginSurfaceMotion(owner: owner)
        registering = false
        await fulfillment(of: [prepared], timeout: 1)
        state.finishSurfaceMotion(owner: owner, token: token)
    }

    func testRealWindowReversalShrinksViewportAndRestoresDismissScheduling() async throws {
        let domain = "app.notchx.tests.window.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        state.expandedAutoDismissDelay = 0.1
        var pointerIsInside = true
        let controller = IslandWindowController(appState: state, pointerSource: {
            IslandPointerSnapshot(location: pointerIsInside
                ? NSPoint(x: NSScreen.main!.frame.midX, y: NSScreen.main!.frame.maxY)
                : NSPoint(x: -100_000, y: -100_000))
        })
        controller.showIsland()
        let window = try XCTUnwrap(controller.windows.first)
        defer {
            controller.hideIsland()
            controller.windows.forEach { $0.close() }
            state.cancelAutoDismiss()
            state.cancelFullExpandedDismiss()
            defaults.removePersistentDomain(forName: domain)
        }
        // No shared media fixtures: this exercises the shipping panel, hosting
        // container and controller callbacks with their real sizing behavior.
        state.isHovering = true
        state.presentNowPlaying()
        await waitUntil { state.isSurfaceMotionActive }
        state.dismiss()
        state.presentNowPlaying()
        await waitUntil { !state.isSurfaceMotionActive && !state.suppressDismissScheduling }
        XCTAssertEqual(state.currentState, .fullExpanded)
        XCTAssertGreaterThan(window.frame.height, state.windowSize(for: .compact).height)

        state.dismiss()
        await waitUntil {
            !state.isSurfaceMotionActive && window.frame.size == state.windowSize
        }
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertEqual(window.frame.size, state.windowSize(for: .compact))
        XCTAssertFalse(state.suppressDismissScheduling)

        // A subsequent expansion must schedule a real dismissal, rather than
        // remaining stuck behind the previous transition's suppression flag.
        state.isHovering = false
        pointerIsInside = false
        state.presentNowPlaying()
        await waitUntil {
            state.currentState == .compact && !state.isSurfaceMotionActive &&
                window.frame.size == state.windowSize(for: .compact)
        }
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertEqual(window.frame.size, state.windowSize(for: .compact))
        XCTAssertFalse(state.suppressDismissScheduling)
    }

    func testOutgoingContentKeepsItsPresentationButDisablesNativeControl() async {
        let button = NSButton(title: "", target: nil, action: nil)
        func content(_ selection: IslandContentSelection) -> some View {
            IslandContentScope(state: .expanded, module: .builtIn(.battery)) {
                NativeControlProbe(button: button)
            }
            .environment(\.islandContentSelection, selection)
        }
        let active = IslandContentSelection(state: .expanded, module: .builtIn(.battery), tab: .home)
        let host = NSHostingView(rootView: content(active))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 80)
        host.layoutSubtreeIfNeeded()
        await waitUntil { button.title == "expanded" && button.isEnabled }
        // The outgoing scope remains mounted while the host selects compact.
        host.rootView = content(IslandContentSelection(state: .compact, module: nil, tab: .home))
        host.layoutSubtreeIfNeeded()
        await waitUntil { !button.isEnabled }
        XCTAssertEqual(button.title, "expanded")
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(4)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out waiting for observable window behavior", file: file, line: line)
    }

    private func withState(_ body: (AppState) -> Void) {
        let domain = "app.notchx.tests.motion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        defer {
            state.cancelAutoDismiss()
            state.cancelFullExpandedDismiss()
            defaults.removePersistentDomain(forName: domain)
        }
        body(state)
    }
}

private struct NativeControlProbe: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandPresentationState) private var presentation
    let button: NSButton

    func makeNSView(context: Context) -> NSButton { button }
    func updateNSView(_ view: NSButton, context: Context) {
        view.title = presentation == .expanded ? "expanded" : "other"
        view.isEnabled = isEnabled
    }
}
