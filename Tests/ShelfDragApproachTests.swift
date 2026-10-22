import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import NotchX

@MainActor
final class ShelfDragApproachTests: XCTestCase {
    private final class Pointer {
        var location = NSPoint(x: 300, y: 240)
        var buttonDown = true
    }

    private func withMonitor(_ body: (AppState, ShelfDragApproachMonitor, NSPasteboard, Pointer, ShelfStore) async throws -> Void) async rethrows {
        let domain = "app.notchx.tests.drag-approach.\(UUID())"
        let preferences = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: preferences)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exports = ShelfExportCoordinator(cache: ShelfExportCache(root: root.appendingPathComponent("exports")))
        let store = ShelfStore(preferences: preferences, managedRoot: root, exports: exports, appState: state)
        store.setEnabled(true)
        let pasteboard = NSPasteboard.withUniqueName()
        let pointer = Pointer()
        let monitor = ShelfDragApproachMonitor(appState: state, pasteboard: pasteboard,
            pointerLocation: { pointer.location }, leftButtonDown: { pointer.buttonDown }) { expanded in
                [expanded ? NSRect(x: 100, y: 0, width: 400, height: 300)
                          : NSRect(x: 200, y: 200, width: 200, height: 100)]
            }
        monitor.start()
        defer {
            monitor.stop()
            state.cancelShelfDragPresentation()
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            store.setEnabled(false)
            try? FileManager.default.removeItem(at: root)
            pasteboard.releaseGlobally()
            preferences.removePersistentDomain(forName: domain)
        }
        try await body(state, monitor, pasteboard, pointer, store)
    }

    private func beginFileDrag(_ monitor: ShelfDragApproachMonitor, _ pasteboard: NSPasteboard) {
        monitor.handleMouseEvent(.leftMouseDown)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([URL(fileURLWithPath: "/tmp/notchx-drag-fixture.pdf") as NSURL]))
        monitor.handleMouseEvent(.leftMouseDragged)
    }

    func testStoppedConsumerIgnoresFreshDragsUntilExplicitlyRestarted() async {
        await withMonitor { state, monitor, pasteboard, _, _ in
            monitor.stop()
            beginFileDrag(monitor, pasteboard)
            monitor.poll()
            XCTAssertFalse(state.isShelfDragActive, "Shared sampling must not reactivate a stopped consumer")
            monitor.start()
            monitor.poll()
            XCTAssertFalse(state.isShelfDragActive, "Restart must not reuse the previous drag payload")
            beginFileDrag(monitor, pasteboard)
            XCTAssertTrue(state.isShelfDragActive)
        }
    }

    func testFreshExternalDragExpandsBeforeReachingIslandAndKeepsReceivingAreaStable() async throws {
        try await withMonitor { state, monitor, pasteboard, pointer, _ in
            XCTAssertTrue(state.shelfExpandOnDragApproach)
            state.shelfAutoOpenOnDrop = false
            beginFileDrag(monitor, pasteboard)
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.shelf)))
            XCTAssertTrue(state.isShelfDragActive, "Approach is independent of the after-drop preference")
            pointer.location = NSPoint(x: 150, y: 40) // below/outside the initial approach band
            monitor.poll()
            XCTAssertTrue(state.isShelfDragActive)
            pointer.location = NSPoint(x: 700, y: 40)
            monitor.poll()
            XCTAssertFalse(state.isShelfDragActive)
            pointer.location = NSPoint(x: 300, y: 240)
            monitor.poll()
            XCTAssertTrue(state.isShelfDragActive, "Leaving and re-entering during one drag works")
            pointer.buttonDown = false // native drag loop omitted mouse-up
            monitor.poll()
            XCTAssertFalse(state.isShelfDragActive)
            pointer.buttonDown = true
            monitor.handleMouseEvent(.leftMouseDragged)
            XCTAssertFalse(state.isShelfDragActive, "A finished drag's pasteboard cannot reopen Shelf")
            try await NativeUI.waitFor("released approach restores automatic collapse") { state.currentState == .compact }
        }
    }

    func testWindowMovementStalePasteboardAndShelfOriginDoNotOpenShelf() async {
        await withMonitor { state, monitor, pasteboard, _, _ in
            pasteboard.setString("previous drag", forType: .string)
            monitor.handleMouseEvent(.leftMouseDown)
            monitor.handleMouseEvent(.leftMouseDragged)
            XCTAssertEqual(state.currentState, .compact, "Mouse/window movement must not reuse a previous payload")
            pasteboard.clearContents()
            pasteboard.setString("shelf item", forType: .string)
            pasteboard.setData(Data([1]), forType: ShelfDragOrigin.pasteboardType)
            monitor.handleMouseEvent(.leftMouseDragged)
            XCTAssertFalse(state.isShelfDragActive)
            XCTAssertEqual(state.currentState, .compact)
            beginFileDrag(monitor, pasteboard)
            XCTAssertTrue(state.isShelfDragActive, "A later external drag is still recognized")
        }
    }

    func testPreferenceModuleDisableAndStopReleaseApproachWithoutBlockingDirectDrops() async {
        await withMonitor { state, monitor, pasteboard, _, _ in
            state.shelfExpandOnDragApproach = false
            beginFileDrag(monitor, pasteboard)
            XCTAssertEqual(state.currentState, .compact)
            let surface = UUID()
            state.beginShelfDragPresentation(owner: surface)
            XCTAssertTrue(state.isShelfDragActive, "Turning off early opening keeps direct drop presentation")
            state.endShelfDragPresentation(owner: surface)
            state.shelfExpandOnDragApproach = true
            beginFileDrag(monitor, pasteboard)
            XCTAssertTrue(state.isShelfDragActive)
            state.shelfExpandOnDragApproach = false
            monitor.poll()
            XCTAssertFalse(state.isShelfDragActive)
            state.shelfExpandOnDragApproach = true
            state.shelfEnabled = false
            beginFileDrag(monitor, pasteboard)
            XCTAssertFalse(state.isShelfDragActive)
            state.shelfEnabled = true
            beginFileDrag(monitor, pasteboard)
            XCTAssertTrue(state.isShelfDragActive)
            monitor.stop()
            XCTAssertFalse(state.isShelfDragActive)
        }
    }

    func testApproachAndSurfaceReleaseOnlyTheirOwnHold() async throws {
        try await withMonitor { state, monitor, pasteboard, _, _ in
            let surface = UUID()
            beginFileDrag(monitor, pasteboard)
            state.beginShelfDragPresentation(owner: surface)
            monitor.handleMouseEvent(.leftMouseUp)
            XCTAssertTrue(state.isShelfDragActive)
            state.endShelfDragPresentation(owner: surface)
            XCTAssertFalse(state.isShelfDragActive)
            try await NativeUI.waitFor("last target leaving resumes collapse without the lock") { state.currentState == .compact }
        }
    }

    func testApproachDoesNotReopenIslandDuringWindowHandoffOrPopoverInteraction() async throws {
        try await withMonitor { state, monitor, pasteboard, _, _ in
            let handoff = try XCTUnwrap(state.beginPresentationHandoff(.window))
            beginFileDrag(monitor, pasteboard)
            XCTAssertFalse(state.isShelfDragActive)
            XCTAssertEqual(state.currentState, .compact)
            state.finishPresentationHandoff(handoff, outcome: .cancelled)
            let control = state.beginControlInteraction(for: .shelf)
            beginFileDrag(monitor, pasteboard)
            XCTAssertFalse(state.isShelfDragActive)
            state.endControlInteraction(control)
            beginFileDrag(monitor, pasteboard)
            XCTAssertTrue(state.isShelfDragActive)
        }
    }

    func testOldImportCompletionKeepsNewDragHeldUntilBothTargetsLeave() async throws {
        for autoOpen in [false, true] {
            try await withMonitor { state, monitor, pasteboard, pointer, store in
                state.shelfAutoOpenOnDrop = autoOpen
                let gate = DeferredImport(requested: expectation(description: "old provider requested"))
                let completed = expectation(description: "old import completed")
                XCTAssertTrue(store.handleDrop(providers: [gate.provider]) { _ in
                    state.presentShelfAfterDrop()
                    completed.fulfill()
                })
                await fulfillment(of: [gate.requested], timeout: 3)
                beginFileDrag(monitor, pasteboard)
                let surface = UUID()
                state.beginShelfDragPresentation(owner: surface)
                let previousModule = state.previousModule
                gate.deliver()
                await fulfillment(of: [completed], timeout: 3)
                XCTAssertEqual(store.visibleItems.map(\.textValue), ["deferred import"])
                XCTAssertTrue(state.isShelfDragActive, "Old completion cannot release a later drag")
                XCTAssertEqual(state.previousModule, previousModule)
                monitor.poll()
                XCTAssertTrue(state.isShelfDragActive)
                pointer.buttonDown = false
                monitor.poll()
                XCTAssertTrue(state.isShelfDragActive, "Surface still holds this drag")
                state.endShelfDragPresentation(owner: surface)
                XCTAssertFalse(state.isShelfDragActive)
                try await NativeUI.waitFor("new drag exits and collapses without fixed expansion") { state.currentState == .compact }
            }
        }
    }

    func testImportCompletionAndTargetExitCollapseWithAutoOpenOffInEitherOrder() async throws {
        for completionFirst in [true, false] {
            try await withMonitor { state, monitor, pasteboard, pointer, store in
                state.shelfAutoOpenOnDrop = false
                beginFileDrag(monitor, pasteboard)
                let surface = UUID()
                state.beginShelfDragPresentation(owner: surface)
                let gate = DeferredImport(requested: expectation(description: "provider requested"))
                let completed = expectation(description: "import completed")
                XCTAssertTrue(store.handleDrop(providers: [gate.provider]) { _ in
                    state.presentShelfAfterDrop()
                    completed.fulfill()
                })
                await fulfillment(of: [gate.requested], timeout: 3)
                if completionFirst {
                    gate.deliver()
                    await fulfillment(of: [completed], timeout: 3)
                }
                pointer.buttonDown = false
                monitor.poll()
                state.endShelfDragPresentation(owner: surface)
                try await NativeUI.waitFor("last exit schedules collapse even after import completion") { state.currentState == .compact }
                if !completionFirst {
                    gate.deliver()
                    await fulfillment(of: [completed], timeout: 3)
                    XCTAssertEqual(state.currentState, .compact, "After-drop auto-open is disabled")
                }
                XCTAssertFalse(state.isShelfDragActive)
                XCTAssertEqual(store.visibleItems.map(\.textValue), ["deferred import"])
            }
        }
    }
}

private final class DeferredImport: @unchecked Sendable {
    let provider = NSItemProvider()
    let requested: XCTestExpectation
    private let lock = NSLock()
    private var completion: (() -> Void)?

    init(requested: XCTestExpectation) {
        self.requested = requested
        provider.registerDataRepresentation(forTypeIdentifier: UTType.utf8PlainText.identifier, visibility: .all) { [weak self] callback in
            guard let self else { callback(nil, CocoaError(.userCancelled)); return nil }
            self.lock.lock()
            self.completion = { callback(Data("deferred import".utf8), nil) }
            self.lock.unlock()
            self.requested.fulfill()
            return nil
        }
    }

    func deliver() {
        lock.lock()
        let callback = completion
        completion = nil
        lock.unlock()
        callback?()
    }
}
