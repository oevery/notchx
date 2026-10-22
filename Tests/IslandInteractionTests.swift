import AppKit
import Quartz
import XCTest
@testable import NotchX

@MainActor
final class IslandInteractionTests: XCTestCase {
    private func withState(_ body: (AppState, UserDefaults) async throws -> Void) async rethrows {
        let domain = "app.notchx.tests.handoff.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: preferences)
        state.presentFullExpandedModule(.shelf)
        defer {
            for session in state.presentationHandoffs.values { state.finishPresentationHandoff(session, outcome: .failed) }
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            state.endSystemEmojiInteraction()
            preferences.removePersistentDomain(forName: domain)
        }
        try await body(state, preferences)
    }

    func testIndependentControlOwnersAndRepeatedReleaseCannotDismissAnotherInteraction() async throws {
        await withState { state, _ in
            let first = state.beginControlInteraction(for: .shelf)
            let second = state.beginControlInteraction(for: .calendar)
            state.endControlInteraction(first)
            state.endControlInteraction(first)
            state.handleHoverChange(false)
            state.dismiss()
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertTrue(state.isControlInteractionActive)
            state.endControlInteraction(second)
            state.dismiss()
            XCTAssertEqual(state.currentState, .compact)
        }
    }

    func testDisableReleasesOnlyThatModulesControlsAndRejectsItsStaleWindowCompletion() async throws {
        try await withState { state, _ in
            let shelfControl = state.beginControlInteraction(for: .shelf)
            let calendarControl = state.beginControlInteraction(for: .calendar)
            let old = try XCTUnwrap(state.beginPresentationHandoff(.window, for: .shelf, returnsToSource: true))
            state.shelfEnabled = false
            state.reconcileEnabledModules()
            XCTAssertFalse(state.isPresentationHandoffActive(old))
            XCTAssertTrue(state.isControlInteractionActive)
            state.shelfEnabled = true
            let fresh = try XCTUnwrap(state.beginPresentationHandoff(.window, for: .shelf))
            state.finishPresentationHandoff(old, outcome: .completed)
            state.endControlInteraction(shelfControl)
            XCTAssertTrue(state.isPresentationHandoffActive(fresh))
            XCTAssertTrue(state.isControlInteractionActive)
            XCTAssertEqual(state.currentState, .compact)
            state.endControlInteraction(calendarControl)
            XCTAssertFalse(state.isControlInteractionActive)
        }
    }

    func testFileSelectionReturnsToSourceOnCompletionOrCancelWhilePlainWindowCloseStaysCompact() async throws {
        for outcome in [IslandHandoffOutcome.completed, .cancelled] {
            try await withState { state, _ in
                let panel = try XCTUnwrap(state.beginPresentationHandoff(.fileSelection, for: .shelf, returnsToSource: true))
                XCTAssertEqual(state.currentState, .compact)
                state.finishPresentationHandoff(panel, outcome: outcome)
                XCTAssertEqual(state.currentState, .fullExpanded)
                XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.shelf)))
                let window = try XCTUnwrap(state.beginPresentationHandoff(.window, for: .shelf))
                state.finishPresentationHandoff(window, outcome: outcome)
                XCTAssertEqual(state.currentState, .compact)
            }
        }
    }

    func testExternalActionsCollapseOnlyAfterSuccessAndRespectLockAndFailureSelection() async throws {
        for locked in [false, true] {
            await withState { state, _ in
                state.lockFullExpandedInPlace = locked
                XCTAssertFalse(state.performExternalAction(for: .shelf) {
                    XCTAssertEqual(state.currentState, .fullExpanded)
                    return false
                })
                XCTAssertEqual(state.currentState, .fullExpanded)
                XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.shelf)))
                XCTAssertTrue(state.presentationHandoffs.isEmpty)
                XCTAssertTrue(state.performExternalAction(for: .shelf) {
                    XCTAssertEqual(state.currentState, .fullExpanded)
                    return true
                })
                XCTAssertEqual(state.currentState, locked ? .fullExpanded : .compact)
                XCTAssertEqual(state.lockFullExpandedInPlace, locked)
                XCTAssertTrue(state.presentationHandoffs.isEmpty)
            }
        }
    }

    func testOverlappingHandoffsAndExplicitNavigationPreventOldCallbacksFromStealingPage() async throws {
        try await withState { state, _ in
            let old = try XCTUnwrap(state.beginPresentationHandoff(.fileSelection, for: .shelf, returnsToSource: true))
            let settings = try XCTUnwrap(state.beginPresentationHandoff(.window))
            state.finishPresentationHandoff(settings, outcome: .cancelled)
            state.finishPresentationHandoff(old, outcome: .completed)
            XCTAssertEqual(state.currentState, .compact)
            state.presentFullExpandedModule(.shelf)
            let external = try XCTUnwrap(state.beginPresentationHandoff(.external, for: .shelf))
            state.presentFullExpandedModule(.calendar)
            state.finishPresentationHandoff(external, outcome: .completed)
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.calendar)))
        }
    }

    func testHandoffCollapsesWithoutBounceButAllowsHoverWhileWindowRemainsOpen() async throws {
        try await withState { state, _ in
            state.endSystemEmojiInteraction()
            state.hoverExpandDelay = 0
            state.isHovering = true
            let session = try XCTUnwrap(state.beginPresentationHandoff(.window))
            XCTAssertFalse(state.canHandleIslandSurfaceGesture, "The outgoing click must not reopen the island after handoff")
            state.handlePointerSample(hovering: true, moved: false)
            state.showHUD(module: .volumeHUD)
            await NativeUI.drainMainQueue()
            XCTAssertEqual(state.currentState, .compact)
            XCTAssertTrue(state.canHandleIslandSurfaceGesture, "A later deliberate action remains available while the window is open")
            state.handlePointerSample(hovering: true, moved: true)
            try await NativeUI.waitFor("movement rearms hover without leaving or closing the window") { state.currentState == .fullExpanded }
            XCTAssertTrue(state.isPresentationHandoffActive(session))
            state.finishPresentationHandoff(session, outcome: .cancelled)
            XCTAssertTrue(state.canHandleIslandSurfaceGesture)
            XCTAssertEqual(state.currentState, .fullExpanded, "Closing an old window cannot collapse a new preview")
            state.endSystemEmojiInteraction()
            state.expandedAutoDismissDelay = 0.02
            state.handleHoverChange(false)
            try await NativeUI.waitFor("preview still collapses after leaving") { state.currentState == .compact }
        }
    }

    func testSettingsMenuEntryDoesNotChangeIslandAndIslandEntryReusesWindowAndCleansUp() async throws {
        await withState { state, _ in
            let controller = SettingsWindowController(appState: state)
            defer { controller.close(); controller.window?.contentViewController = nil }
            controller.show()
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertTrue(state.presentationHandoffs.isEmpty)
            let window = controller.window
            controller.show(fromIsland: state)
            XCTAssertTrue(controller.window === window)
            XCTAssertEqual(state.currentState, .compact)
            XCTAssertEqual(state.presentationHandoffs.count, 1)
            controller.show(fromIsland: state)
            XCTAssertEqual(state.presentationHandoffs.count, 1)
            controller.close()
            XCTAssertTrue(state.presentationHandoffs.isEmpty)
            XCTAssertEqual(state.currentState, .compact)
        }
    }

    func testLockedSettingsHandoffPreservesIslandAndFitsWindowBelowSource() async throws {
        try await withState { state, _ in
            let screen = try XCTUnwrap(NSScreen.main)
            let source = IslandPanel()
            source.isReleasedWhenClosed = false
            source.setFrame(NSRect(x: screen.visibleFrame.midX - 300, y: screen.visibleFrame.maxY - 180,
                                   width: 600, height: 180), display: false)
            source.orderFront(nil)
            let controller = SettingsWindowController(appState: state)
            defer { controller.close(); controller.window?.contentViewController = nil; source.close() }
            state.lockFullExpandedInPlace = true
            controller.show(fromIsland: state, sourceWindow: source)
            let settings = try XCTUnwrap(controller.window)
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertTrue(state.lockFullExpandedInPlace)
            XCTAssertLessThanOrEqual(settings.frame.maxY, source.frame.minY - 12 + 0.5)
            XCTAssertTrue(screen.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(settings.frame))
            controller.close()
            XCTAssertTrue(state.presentationHandoffs.isEmpty)
            XCTAssertEqual(state.currentState, .fullExpanded)
        }
    }

    func testNativeShelfFilePanelCancelReturnsButDisableClosesWithoutRestoringOrChangingItems() async throws {
        try await withState { state, preferences in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = ShelfStore(preferences: preferences, managedRoot: root, appState: state)
            store.setEnabled(true)
            let original = ShelfItem.file(from: root.appendingPathComponent("missing.txt"))
            store.add([original])
            defer { store.setEnabled(false); try? FileManager.default.removeItem(at: root) }
            store.locateFile(original)
            let first = try XCTUnwrap(store.activeOpenPanel)
            try await NativeUI.waitFor("native locate panel appears") { first.isVisible }
            XCTAssertEqual(state.currentState, .compact)
            store.openAirDropPicker()
            XCTAssertTrue(store.activeOpenPanel === first, "A second entry must not orphan the active panel")
            XCTAssertEqual(state.presentationHandoffs.count, 1)
            first.cancel(nil)
            try await NativeUI.waitFor("native cancel returns to Shelf") { store.activeOpenPanel == nil }
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.shelf)))
            store.openAirDropPicker()
            let second = try XCTUnwrap(store.activeOpenPanel)
            try await NativeUI.waitFor("native AirDrop selection appears") { second.isVisible }
            store.setEnabled(false)
            try await NativeUI.waitFor("disable closes native file panel") { !second.isVisible }
            XCTAssertNil(store.activeOpenPanel)
            XCTAssertEqual(state.currentState, .compact)
            XCTAssertTrue(state.presentationHandoffs.isEmpty)
            store.setEnabled(true)
            await NativeUI.drainMainQueue()
            XCTAssertEqual(store.items, [original])
            XCTAssertEqual(state.currentState, .compact)
        }
    }

    func testSharingPickerKeepsSourceStableAndReleasesOnCancelFailureAndDisable() async throws {
        try await withState { state, preferences in
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let store = ShelfStore(preferences: preferences, managedRoot: root, appState: state)
            store.setEnabled(true)
            let source = IslandPanel()
            source.isReleasedWhenClosed = false
            source.setFrame(NSRect(x: 100, y: 100, width: 600, height: 200), display: false)
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
            source.contentView = view
            source.orderFront(nil)
            defer { store.setEnabled(false); source.close(); try? FileManager.default.removeItem(at: root) }
            let item = ShelfItem.text("Sharing fixture")
            store.share(items: [item], from: view)
            XCTAssertTrue(state.isControlInteractionActive)
            state.dismiss()
            XCTAssertEqual(state.currentState, .fullExpanded)
            try await NativeUI.waitFor("native sharing picker prepared") { store.activeSharingPicker != nil }
            let picker = try XCTUnwrap(store.activeSharingPicker)
            // The share menu is an asynchronous system UI. Deliver its public
            // cancellation callback explicitly instead of racing menu animation.
            picker.delegate?.sharingServicePicker?(picker, didChoose: nil)
            try await NativeUI.waitFor("cancel releases sharing hold") { !state.isControlInteractionActive }
            XCTAssertNil(store.activeSharingPicker)
            XCTAssertTrue(state.presentationHandoffs.isEmpty)
            store.share(items: [ShelfItem.file(from: root.appendingPathComponent("missing.txt"))], from: view)
            XCTAssertTrue(state.isControlInteractionActive)
            try await NativeUI.waitFor("failed export releases sharing hold") { !state.isControlInteractionActive }
            XCTAssertFalse(store.operationMessage.isEmpty)
            XCTAssertNil(store.activeSharingPicker)
            store.share(items: [item], from: view)
            try await NativeUI.waitFor("second native sharing picker") { store.activeSharingPicker != nil }
            let disabledPicker = try XCTUnwrap(store.activeSharingPicker)
            store.setEnabled(false)
            XCTAssertNil(disabledPicker.delegate)
            XCTAssertFalse(state.isControlInteractionActive)
            XCTAssertTrue(state.presentationHandoffs.isEmpty)
        }
    }

    func testNativeQuickLookCloseEndsHandoffAndCanReopenWithoutLeakingSession() async throws {
        try await withState { state, _ in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("notchx-preview-\(UUID().uuidString).txt")
            try Data("Preview fixture".utf8).write(to: url)
            let controller = ShelfQuickLookController(appState: state)
            defer { controller.close(); try? FileManager.default.removeItem(at: url) }
            controller.preview(url)
            let panel = try XCTUnwrap(QLPreviewPanel.shared())
            try await NativeUI.waitFor("native Quick Look appears") { panel.isVisible }
            XCTAssertEqual(state.currentState, .compact)
            XCTAssertEqual(state.presentationHandoffs.count, 1)
            controller.preview(url)
            XCTAssertEqual(state.presentationHandoffs.count, 1)
            panel.performClose(nil)
            try await NativeUI.waitFor("native preview closes and releases handoff") { !panel.isVisible && state.presentationHandoffs.isEmpty }
            XCTAssertFalse(panel.isVisible)
            XCTAssertNil(panel.dataSource)
            XCTAssertNil(controller.previewPanel(panel, previewItemAt: 0), "A late system item request after close must be harmless")
            XCTAssertEqual(state.currentState, .compact)
            controller.preview(url)
            XCTAssertEqual(state.presentationHandoffs.count, 1)
            controller.close()
            try await NativeUI.waitFor("programmatic preview close finishes") { !panel.isVisible }
            XCTAssertTrue(state.presentationHandoffs.isEmpty)
            XCTAssertFalse(panel.isVisible)
        }
    }

    func testMinimizedSettingsShouldNotDisableExplicitSurfaceGestures() async throws {
        try await withState { state, _ in
            let controller = SettingsWindowController(appState: state)
            defer { controller.close(); controller.window?.contentViewController = nil }
            controller.show(fromIsland: state)
            let settings = try XCTUnwrap(controller.window)
            settings.miniaturize(nil)
            try await NativeUI.waitFor("settings minimized") { settings.isMiniaturized }
            XCTAssertEqual(state.currentState, .compact)
            XCTAssertTrue(state.canHandleIslandSurfaceGesture, "A deliberate surface click/swipe must remain usable while settings is minimized")
        }
    }

    func testSuccessfulLatestExternalActionShouldCollapseDespiteOlderSettingsWindow() async throws {
        try await withState { state, _ in
            state.lockFullExpandedInPlace = true
            let settings = try XCTUnwrap(state.beginPresentationHandoff(.window))
            state.lockFullExpandedInPlace = false
            XCTAssertTrue(state.performExternalAction(for: .shelf) { true })
            XCTAssertEqual(state.currentState, .compact, "The older settings session should not block the latest successful external action")
            XCTAssertTrue(state.isPresentationHandoffActive(settings))
        }
    }

    func testReactivatingExistingSettingsAfterUnlockShouldCollapseAgain() async throws {
        await withState { state, _ in
            let controller = SettingsWindowController(appState: state)
            defer { controller.close(); controller.window?.contentViewController = nil }
            state.lockFullExpandedInPlace = true
            controller.show(fromIsland: state)
            let firstWindow = controller.window
            state.lockFullExpandedInPlace = false
            controller.show(fromIsland: state)
            XCTAssertTrue(controller.window === firstWindow)
            XCTAssertEqual(state.currentState, .compact, "Reusing a window must still apply the new activation's handoff policy")
        }
    }

    func testSlowSharingHonorsCurrentSourceAcrossWindowAndPageChanges() async throws {
        enum Destination { case sameSource, newWindow, otherPage, airDropNewWindow }
        for destination in [Destination.sameSource, .newWindow, .otherPage, .airDropNewWindow] {
            try await withState { state, preferences in
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                let file = root.appendingPathComponent("source.txt")
                try Data("source".utf8).write(to: file)
                let gate = TransferTestGate(started: expectation(description: "export copy started"))
                var operations = ShelfFileOperations.live
                operations.copy = { source, target in gate.pause(); try FileManager.default.copyItem(at: source, to: target) }
                let exports = ShelfExportCoordinator(cache: ShelfExportCache(root: root.appendingPathComponent("exports"), operations: operations))
                let store = ShelfStore(preferences: preferences, managedRoot: root.appendingPathComponent("managed"), exports: exports, appState: state)
                store.setEnabled(true)
                let source = IslandPanel()
                source.isReleasedWhenClosed = false
                source.setFrame(NSRect(x: 100, y: 100, width: 600, height: 200), display: false)
                let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 200))
                source.contentView = view
                source.orderFront(nil)
                state.didChangeState = { _, newState in
                    if newState == .compact { source.setFrame(NSRect(x: 100, y: 100, width: 240, height: 40), display: false) }
                }
                defer { gate.open(); store.setEnabled(false); source.close(); state.didChangeState = nil; try? FileManager.default.removeItem(at: root) }
                if destination == .airDropNewWindow { store.shareViaAirDrop(items: [ShelfItem.file(from: file)]) }
                else { store.share(items: [ShelfItem.file(from: file)], from: view) }
                await fulfillment(of: [gate.started], timeout: 3)
                var settings: IslandPresentationHandoff?
                switch destination {
                case .sameSource: break
                case .newWindow, .airDropNewWindow:
                    settings = try XCTUnwrap(state.beginPresentationHandoff(.window))
                    XCTAssertEqual(state.currentState, .compact)
                case .otherPage: state.presentFullExpandedModule(.calendar)
                }
                XCTAssertTrue(source.isVisible)
                gate.open()
                try await NativeUI.waitFor("export reconciles its presentation") { store.activeSharingPicker != nil || !state.isControlInteractionActive }
                if destination == .sameSource {
                    let picker = try XCTUnwrap(store.activeSharingPicker)
                    XCTAssertTrue(state.isControlInteractionActive)
                    picker.delegate?.sharingServicePicker?(picker, didChoose: nil)
                } else {
                    XCTAssertNil(store.activeSharingPicker, "A late export must not present over a newer intent")
                }
                XCTAssertFalse(state.isControlInteractionActive)
                if let settings { XCTAssertTrue(state.isPresentationHandoffActive(settings)) }
                if destination == .otherPage {
                    XCTAssertEqual(state.currentState, .fullExpanded)
                    XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.calendar)))
                }
                XCTAssertEqual(try Data(contentsOf: file), Data("source".utf8))
            }
        }
    }

    func testLockedSettingsMustKeepItsDeclaredContentMinimumUsable() async throws {
        try await withState { state, _ in
            let screen = try XCTUnwrap(NSScreen.main)
            let source = IslandPanel()
            source.isReleasedWhenClosed = false
            source.setFrame(NSRect(x: screen.visibleFrame.midX - 300, y: screen.visibleFrame.minY + 220,
                                   width: 600, height: screen.visibleFrame.height - 220), display: false)
            source.orderFront(nil)
            let controller = SettingsWindowController(appState: state)
            defer { controller.close(); controller.window?.contentViewController = nil; source.close() }
            state.lockFullExpandedInPlace = true
            controller.show(fromIsland: state, sourceWindow: source)
            let window = try XCTUnwrap(controller.window)
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(window.contentView?.bounds.height ?? 0, 560, "SettingsView declares a 560pt minimum; avoidance must choose a usable fallback")
            XCTAssertTrue(screen.visibleFrame.insetBy(dx: -1, dy: -1).contains(window.frame),
                "visible=\(NSStringFromRect(screen.visibleFrame)) source=\(NSStringFromRect(source.frame)) settings=\(NSStringFromRect(window.frame)) content=\(NSStringFromRect(window.contentView?.bounds ?? .zero))")
        }
    }
}
