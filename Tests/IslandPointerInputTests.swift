import AppKit
import XCTest
@testable import NotchX

@MainActor
final class IslandPointerInputTests: XCTestCase {
    private final class Pointer {
        var location = NSPoint(x: -100_000, y: -100_000)
        var buttons = 0
        var snapshot: IslandPointerSnapshot { .init(location: location, pressedButtons: buttons) }
    }

    private func withState(_ body: (AppState) async throws -> Void) async rethrows {
        let domain = "app.notchx.tests.pointer." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: preferences)
        state.nowPlayingEnabled = false
        state.agentEnabled = false
        state.hoverExpandDelay = 0.02
        state.expandedAutoDismissDelay = 0.04
        defer {
            state.setPointerInputAvailable(false)
            state.endSystemEmojiInteraction()
            preferences.removePersistentDomain(forName: domain)
        }
        try await body(state)
    }

    private func withController(_ body: (AppState, IslandWindowController, Pointer) async throws -> Void) async throws {
        try await withState { state in
            let pointer = Pointer()
            let controller = IslandWindowController(appState: state, pointerSource: { pointer.snapshot })
            controller.showIsland()
            defer {
                controller.hideIsland()
                controller.windows.forEach { $0.contentView = nil; $0.close() }
            }
            try await NativeUI.waitFor("initial window settles") { !state.isSurfaceMotionActive && !state.suppressDismissScheduling }
            try await body(state, controller, pointer)
        }
    }

    func testLogicalRegionsKeepApproachMarginHysteresisAndInclusiveScreenEdge() {
        let screen = NSRect(x: -1000, y: -600, width: 1000, height: 600)
        let region = IslandPointerRegion(frame: NSRect(x: -600, y: -36, width: 200, height: 36), screenFrame: screen)
        XCTAssertTrue(region.contains(NSPoint(x: -500, y: 0), keepingHover: false))
        XCTAssertTrue(region.contains(NSPoint(x: -603, y: -12), keepingHover: false))
        XCTAssertFalse(region.contains(NSPoint(x: -606, y: -12), keepingHover: false))
        XCTAssertTrue(region.contains(NSPoint(x: -606, y: -12), keepingHover: true))
        XCTAssertFalse(region.contains(NSPoint(x: -500, y: 1), keepingHover: true))
        XCTAssertFalse(region.contains(NSPoint(x: -609, y: -12), keepingHover: true))
    }

    func testPhysicalReleaseRecoversMissingSurfaceDragExitWithoutClearingOtherInteractions() async throws {
        try await withController { state, controller, pointer in
            pointer.buttons = 1
            let surfaceOwner = UUID()
            state.beginShelfDragPresentation(owner: surfaceOwner)
            let control = state.beginControlInteraction(for: .calendar)
            controller.samplePointer()
            XCTAssertTrue(state.isShelfDragActive)
            pointer.buttons = 0
            // No mouse-up event and no SwiftUI target-exit callback.
            controller.samplePointer()
            XCTAssertFalse(state.isShelfDragActive)
            XCTAssertTrue(state.isControlInteractionActive)
            state.endControlInteraction(control)
            try await NativeUI.waitFor("physical drag release restores collapse") { state.currentState == .compact }
        }
    }

    func testInactiveSpaceDoesNotHoverAndReturningRestoresSampling() async throws {
        try await withState { state in
            let pointer = Pointer()
            var onActiveSpace = true
            let controller = IslandWindowController(appState: state, pointerSource: { pointer.snapshot },
                                                    panelIsOnActiveSpace: { _ in onActiveSpace })
            controller.showIsland()
            defer {
                controller.hideIsland()
                controller.windows.forEach { $0.contentView = nil; $0.close() }
            }
            let region = try XCTUnwrap(controller.pointerRegions().first)
            pointer.location = NSPoint(x: region.frame.midX, y: region.frame.maxY)
            controller.samplePointer()
            XCTAssertTrue(state.isHovering)
            onActiveSpace = false
            controller.samplePointer()
            XCTAssertTrue(controller.pointerRegions().isEmpty)
            XCTAssertTrue(controller.shelfDragApproachFrames(keepingPresentation: false).isEmpty)
            XCTAssertFalse(state.isHovering)
            state.dismiss()
            onActiveSpace = true
            NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
            try await NativeUI.waitFor("active-Space return restores pointer sampling") { state.isHovering && state.currentState == .fullExpanded }
        }
    }

    func testHideAndShowDuringSurfaceMotionRestoresInputAndCollapse() async throws {
        try await withController { state, controller, pointer in
            let region = try XCTUnwrap(controller.pointerRegions().first)
            pointer.location = NSPoint(x: region.frame.midX, y: region.frame.maxY)
            controller.samplePointer()
            state.open()
            controller.hideIsland()
            XCTAssertFalse(state.isHovering)
            state.dismiss()
            controller.showIsland()
            try await NativeUI.waitFor("show recovers hover after interrupted surface motion") { state.isHovering && state.currentState == .fullExpanded }
            pointer.location = NSPoint(x: -100_000, y: -100_000)
            controller.samplePointer()
            try await NativeUI.waitFor("show recovers ordinary leave collapse") { state.currentState == .compact }
        }
    }

    func testRegionsAggregateMultipleDisplaysAndRemovedRegionsCannotKeepHover() {
        let a = IslandPointerRegion(frame: NSRect(x: 200, y: 560, width: 200, height: 40),
                                    screenFrame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let b = IslandPointerRegion(frame: NSRect(x: -800, y: 760, width: 200, height: 40),
                                    screenFrame: NSRect(x: -1000, y: 0, width: 1000, height: 800))
        let point = NSPoint(x: -700, y: 800)
        XCTAssertTrue(IslandPointerRegion.isHovering(at: point, regions: [a, b], keepingHover: false))
        XCTAssertFalse(IslandPointerRegion.isHovering(at: point, regions: [a], keepingHover: true))
        XCTAssertFalse(IslandPointerRegion.isHovering(at: point, regions: [], keepingHover: true))
    }

    func testControllerSamplesRecoverMissingEnterAndExitWithoutSwiftUICallbacks() async throws {
        try await withController { state, controller, pointer in
            let region = try XCTUnwrap(controller.pointerRegions().first)
            pointer.location = NSPoint(x: region.frame.midX, y: region.frame.maxY)
            controller.samplePointer()
            XCTAssertTrue(state.isHovering)
            try await NativeUI.waitFor("missing enter recovered") { state.currentState == .fullExpanded }
            pointer.location = NSPoint(x: -100_000, y: -100_000)
            controller.samplePointer()
            XCTAssertFalse(state.isHovering)
            try await NativeUI.waitFor("missing exit recovered after animation") { state.currentState == .compact }
        }
    }

    func testRepeatedSamplesDoNotPostponeExpansionOrCollapseDeadlines() async throws {
        try await withState { state in
            for _ in 0..<12 {
                state.handlePointerSample(hovering: true, moved: false)
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(state.currentState, .fullExpanded)
            for _ in 0..<12 {
                state.handlePointerSample(hovering: false, moved: false)
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(state.currentState, .compact, "Compensation samples must not renew the leave deadline")
        }
    }

    func testControllerCompensationTimerRecoversAnEntireMissingEventStream() async throws {
        try await withController { state, controller, pointer in
            let region = try XCTUnwrap(controller.pointerRegions().first)
            pointer.location = NSPoint(x: region.frame.midX, y: region.frame.maxY)
            // No manual sample and no posted mouse event: exercise the shipping timer.
            try await NativeUI.waitFor("timer recovers missed enter") { state.currentState == .fullExpanded }
            pointer.location = NSPoint(x: -100_000, y: -100_000)
            try await NativeUI.waitFor("timer recovers missed exit") { state.currentState == .compact }
        }
    }

    func testMovementBeforeWindowActionIsNotMistakenForMovementAfterCollapse() async throws {
        try await withController { state, controller, pointer in
            let region = try XCTUnwrap(controller.pointerRegions().first)
            pointer.location = NSPoint(x: region.frame.midX, y: region.frame.maxY)
            controller.samplePointer()
            try await NativeUI.waitFor("initial hover opens") { state.currentState == .fullExpanded }
            let settings = SettingsWindowController(appState: state)
            defer { settings.close(); settings.window?.contentViewController = nil }
            // The input event moved since the last sample, but its action is
            // already collapsing the island before the queued sample runs.
            pointer.location.x += 1
            settings.show(fromIsland: state)
            controller.samplePointer()
            try await NativeUI.waitFor("outgoing collapse settles") { !state.isSurfaceMotionActive && !state.suppressDismissScheduling }
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(state.currentState, .compact)
            pointer.location.x += 1
            controller.samplePointer()
            try await NativeUI.waitFor("subsequent movement rearms without exit") { state.currentState == .fullExpanded }
        }
    }

    func testControllerKeepsExpandedShadowMarginButNotMaximumReservedViewport() async throws {
        try await withController { state, controller, pointer in
            state.presentFullExpandedModule(.calendar)
            state.lockFullExpandedInPlace = true
            try await NativeUI.waitFor("expanded frame settles") { !state.isSurfaceMotionActive && !state.suppressDismissScheduling }
            let region = try XCTUnwrap(controller.pointerRegions().first)
            let window = try XCTUnwrap(controller.windows.first)
            XCTAssertEqual(region.frame, window.frame)
            pointer.location = NSPoint(x: region.frame.minX + 2, y: region.frame.midY)
            controller.samplePointer()
            XCTAssertTrue(state.isHovering, "The deliberate shadow/retention margin stays interactive")
            state.lockFullExpandedInPlace = false
            state.dismiss()
            try await NativeUI.waitFor("collapse settles") { !state.isSurfaceMotionActive && !state.suppressDismissScheduling }
            XCTAssertLessThan(try XCTUnwrap(controller.pointerRegions().first).frame.width, region.frame.width)
            try await NativeUI.waitFor("settled logical region publishes a fresh pointer sample") { !state.isHovering }
        }
    }

    func testHiddenPanelAndHostStopClearInputAndShowingAgainResamples() async throws {
        try await withController { state, controller, pointer in
            let window = try XCTUnwrap(controller.windows.first)
            pointer.location = NSPoint(x: window.frame.midX, y: window.frame.maxY)
            controller.samplePointer()
            window.orderOut(nil)
            controller.samplePointer()
            XCTAssertFalse(state.isHovering)
            XCTAssertTrue(controller.pointerRegions().isEmpty)
            try await Task.sleep(for: .milliseconds(80))
            XCTAssertEqual(state.currentState, .compact, "Hidden input cannot execute a pending expansion")
            controller.hideIsland()
            controller.showIsland()
            controller.showIsland()
            XCTAssertEqual(controller.windows.count, 1, "Repeated start is idempotent")
            controller.samplePointer()
            try await NativeUI.waitFor("stationary pointer resampled after restart") { state.currentState == .fullExpanded }
        }
    }

    func testControlReleaseRestoresHoverWithoutAnotherEnterEvent() async throws {
        try await withState { state in
            let token = state.beginControlInteraction(for: .calendar)
            state.handleHoverChange(true)
            await NativeUI.drainMainQueue()
            XCTAssertEqual(state.currentState, .compact)
            state.endControlInteraction(token)
            try await NativeUI.waitFor("control release rearms existing hover") { state.currentState == .fullExpanded }
        }
    }

    func testShortProtectionExpiryRestoresHoverAndLeaveScheduling() async throws {
        try await withState { state in
            state.beginCompactControlInteraction(timeout: 0.03)
            state.handleHoverChange(true)
            try await NativeUI.waitFor("short protection expiry rearms hover") { state.currentState == .fullExpanded }
            state.beginCompactControlInteraction(timeout: 0.03)
            state.handleHoverChange(false)
            try await NativeUI.waitFor("expiry also restores collapse") { state.currentState == .compact }
        }
    }

    func testActivityHoldReleaseRestoresDismissalWithoutPointerMovement() async throws {
        try await withState { state in
            state.showHUD(module: .calendar, autoDismiss: false)
            state.holdPresentation(for: .builtIn(.calendar))
            state.handleHoverChange(false)
            state.releasePresentationHold(for: .builtIn(.calendar))
            try await NativeUI.waitFor("activity release resumes collapse") { state.currentState == .compact }
        }
    }

    func testOldWindowCloseCannotCancelPendingHoverOrAffectNewPage() async throws {
        try await withState { state in
            let old = try XCTUnwrap(state.beginPresentationHandoff(.window))
            state.open() // supersedes only the old return intent, not its resource lifetime
            state.dismiss()
            state.handleHoverChange(true)
            state.finishPresentationHandoff(old, outcome: .cancelled)
            try await NativeUI.waitFor("old close preserves a pending hover") { state.currentState == .fullExpanded }
            let external = try XCTUnwrap(state.beginPresentationHandoff(.external, for: .calendar))
            state.presentFullExpandedModule(.shelf)
            state.finishPresentationHandoff(external, outcome: .completed)
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.shelf)))
        }
    }

    func testSettingsStaysOpenOrMinimizedWhileHoverAndLeaveRemainUsable() async throws {
        try await withState { state in
            let settings = SettingsWindowController(appState: state)
            defer { settings.close(); settings.window?.contentViewController = nil }
            state.open()
            state.handleHoverChange(true)
            settings.show(fromIsland: state)
            XCTAssertEqual(state.currentState, .compact)
            state.handlePointerSample(hovering: true, moved: false)
            await NativeUI.drainMainQueue()
            XCTAssertEqual(state.currentState, .compact, "No geometry-only bounce from the outgoing click")
            state.handlePointerSample(hovering: true, moved: true)
            try await NativeUI.waitFor("settings open does not block hover") { state.currentState == .fullExpanded }
            settings.window?.miniaturize(nil)
            state.handleHoverChange(false)
            try await NativeUI.waitFor("live window does not block collapse") { state.currentState == .compact }
            state.handleHoverChange(true)
            try await NativeUI.waitFor("minimized window does not block hover") { state.currentState == .fullExpanded }
        }
    }

    func testDisableReleasesOnlyItsOwnControlAndRestoresHover() async throws {
        try await withState { state in
            let calendar = state.beginControlInteraction(for: .calendar)
            let shelf = state.beginControlInteraction(for: .shelf)
            state.handleHoverChange(true)
            state.calendarEnabled = false
            state.reconcileEnabledModules()
            XCTAssertTrue(state.isControlInteractionActive)
            state.endControlInteraction(calendar)
            XCTAssertTrue(state.isControlInteractionActive)
            state.endControlInteraction(shelf)
            try await NativeUI.waitFor("last owner release restores hover") { state.currentState == .fullExpanded }
        }
    }
}
