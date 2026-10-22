import AppKit
import XCTest
@testable import NotchX

@MainActor
final class ShelfWindowTests: XCTestCase {
    private func withWindow(startOnShelf: Bool = false,
                            _ body: (AppState, ShelfStore, IslandWindowController, NSWindow, [ShelfItem]) async throws -> Void) async throws {
        let domain = "app.notchx.tests.shelf-window.\(UUID())"
        let preferences = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: preferences)
        let screen = try XCTUnwrap(NSScreen.main)
        state.displayIdentifier = ScreenDetector.displayIDString(for: screen) ?? ""
        state.lockFullExpandedInPlace = true
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exports = ShelfExportCoordinator(cache: ShelfExportCache(root: root.appendingPathComponent("exports")))
        let store = ShelfStore(preferences: preferences, managedRoot: root, exports: exports, appState: state)
        store.setEnabled(true)
        let items = (0..<20).map { index in
            ShelfItem(kind: .text, displayName: "\(index) 长文稿 A long document name.pdf", textValue: "sample-\(index)",
                      addedAt: Date(timeIntervalSince1970: Double(1_000 - index)))
        }
        store.add(items)
        if startOnShelf { state.presentFullExpandedModule(.shelf) }
        let controller = IslandWindowController(appState: state, shelf: store, pointerSource: {
            IslandPointerSnapshot(location: NSPoint(x: -100_000, y: -100_000))
        })
        controller.showIsland()
        let window = try XCTUnwrap(controller.windows.first)
        defer {
            controller.hideIsland()
            controller.windows.forEach { $0.contentView = nil; $0.close() }
            store.setEnabled(false)
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            preferences.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(state, store, controller, window, items)
    }

    func testCompleteWindowSwitchingKeepsNavigationAndShelfInsideViewport() async throws {
        for startOnShelf in [false, true] {
            try await withWindow(startOnShelf: startOnShelf) { state, _, _, window, items in
                state.open()
                for tab: FullExpandedTab in [.home, .module(.builtIn(.shelf)), .module(.builtIn(.nowPlaying)),
                                             .home, .module(.builtIn(.shelf))] {
                    state.selectFullExpandedTab(tab)
                    try await settle(state, window)
                    let content = try XCTUnwrap(window.contentView)
                    let hosting = try XCTUnwrap(content.subviews.first)
                    XCTAssertGreaterThanOrEqual(hosting.frame.height, state.currentSize.height, "hosting capacity: \(tab)")
                    XCTAssertEqual(hosting.frame.maxY, content.bounds.maxY, accuracy: 0.5, "top anchor: \(tab)")
                    try assertVisible("island-module-navigation", in: window)
                    if tab == .module(.builtIn(.shelf)) {
                        for id in ["shelf-airdrop", "shelf-toolbar", "shelf-search", "shelf-file-scroll", "shelf-feedback"] {
                            try assertVisible(id, in: window)
                        }
                        let viewport = try NativeUI.frame(in: content, id: "shelf-file-scroll")
                        for item in items.prefix(6) {
                            let card = try NativeUI.frame(in: content, id: "shelf-item-\(item.id)")
                            XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(card), "Both complete rows must fit: \(card) in \(viewport)")
                        }
                        if let thirdRow = NativeUI.find(in: content, id: "shelf-item-\(items[6].id)")?.accessibilityFrame?() {
                            XCTAssertFalse(viewport.intersects(thirdRow), "A partial third row should not be shown")
                        }
                        let airDrop = try NativeUI.frame(in: content, id: "shelf-airdrop")
                        let tray = try NativeUI.frame(in: content, id: "shelf-tray")
                        XCTAssertEqual(airDrop.minY, tray.minY, accuracy: 1)
                        XCTAssertEqual(airDrop.maxY, tray.maxY, accuracy: 1)
                    }
                }
            }
        }
    }

    func testFullWindowSelectionReusesToolbarWithoutShrinkingFiles() async throws {
        try await withWindow { state, store, _, window, items in
            state.presentFullExpandedModule(.shelf)
            try await settle(state, window)
            let content = try XCTUnwrap(window.contentView)
            let before = try NativeUI.frame(in: content, id: "shelf-file-scroll")
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            NSApp.postEvent(event, atStart: false)
            _ = try await NativeUI.waitForElement(in: content, id: "shelf-remove-selected")
            XCTAssertEqual(try NativeUI.frame(in: content, id: "shelf-file-scroll"), before)
            let toolbar = try NativeUI.frame(in: content, id: "shelf-toolbar")
            for id in ["shelf-search", "shelf-remove-selected"] {
                XCTAssertTrue(toolbar.insetBy(dx: -0.5, dy: -0.5).contains(try NativeUI.frame(in: content, id: id)))
                try assertVisible(id, in: window)
            }
            XCTAssertEqual(Set(store.visibleItems.map(\.id)), Set(items.map(\.id)))
            state.selectFullExpandedTab(.home)
            try await settle(state, window)
            try assertVisible("island-module-navigation", in: window)
        }
    }

    func testShelfReversalAndCompactReopenKeepHostingCapacityAndTopAnchor() async throws {
        for reduced in [false, true] {
            try await withWindow { state, _, _, window, _ in
                state.reduceMotion = reduced
                state.lockFullExpandedInPlace = false
                state.presentFullExpandedModule(.shelf)
                try await NativeUI.waitFor("shelf surface motion begins", in: window.contentView) { state.isSurfaceMotionActive }
                state.dismiss()
                state.presentNowPlaying()
                state.presentFullExpandedModule(.shelf)
                state.lockFullExpandedInPlace = true
                try await settle(state, window)
                try assertVisible("island-module-navigation", in: window)
                try assertVisible("shelf-feedback", in: window)
                let content = try XCTUnwrap(window.contentView)
                let hosting = try XCTUnwrap(content.subviews.first)
                let capacity = hosting.frame.size
                state.lockFullExpandedInPlace = false
                state.dismiss()
                try await settle(state, window)
                XCTAssertEqual(state.currentState, .compact)
                XCTAssertEqual(window.frame.size, state.windowSize(for: .compact))
                XCTAssertEqual(hosting.frame.size, capacity, "Collapse must not shrink the backing canvas during a reversal")
                XCTAssertEqual(hosting.frame.maxY, content.bounds.maxY, accuracy: 0.5)
                state.presentFullExpandedModule(.shelf)
                state.lockFullExpandedInPlace = true
                try await settle(state, window)
                for id in ["island-module-navigation", "shelf-toolbar", "shelf-feedback"] { try assertVisible(id, in: window) }
            }
        }
    }

    private func settle(_ state: AppState, _ window: NSWindow) async throws {
        do {
            try await NativeUI.waitFor("full window presentation settles", in: window.contentView) {
                !state.isSurfaceMotionActive && !state.suppressDismissScheduling && window.frame.size == state.windowSize
            }
        } catch {
            print("Window settle diagnostics: state=\(state.currentState), tab=\(state.fullExpandedSelectedTab), motion=\(state.isSurfaceMotionActive), suppressed=\(state.suppressDismissScheduling), actual=\(window.frame.size), target=\(state.windowSize)")
            throw error
        }
    }

    func testApproachBandPrecedesCompactWindowWithoutAddingAnInvisibleWindow() async throws {
        try await withWindow { state, _, controller, window, _ in
            let frame = window.frame
            let windows = controller.windows.map(\.windowNumber)
            let regions = controller.shelfDragApproachFrames(keepingPresentation: false)
            let region = try XCTUnwrap(regions.first)
            let approach = NSPoint(x: frame.midX, y: frame.minY - 40)
            XCTAssertTrue(region.contains(approach))
            XCTAssertFalse(frame.contains(approach), "Expand before content reaches the compact surface")
            XCTAssertLessThan(region.width, state.size(for: .fullExpanded).width)
            XCTAssertEqual(window.frame, frame)
            XCTAssertEqual(controller.windows.map(\.windowNumber), windows)
            let owner = UUID()
            state.beginShelfDragPresentation(owner: owner)
            controller.hideIsland()
            XCTAssertFalse(state.isShelfDragActive)
            XCTAssertTrue(controller.shelfDragApproachFrames(keepingPresentation: true).isEmpty)
        }
    }

    func testRemovalAndUndoKeepEqualDropPanesAndRestoreRowsUnderBothMotionPolicies() async throws {
        for reduced in [false, true] {
            try await withWindow(startOnShelf: true) { state, store, _, window, items in
                state.reduceMotion = reduced
                try await settle(state, window)
                let content = try XCTUnwrap(window.contentView)
                let first = try NativeUI.frame(in: content, id: "shelf-item-\(items[0].id)")
                let pane = try NativeUI.frame(in: content, id: "shelf-tray")
                let removed = Array(items.prefix(3))
                let now = Date()
                store.requestRemoval(removed, now: now)
                XCTAssertEqual(store.visibleItems.count, 17, "Animation must not defer model removal")
                XCTAssertEqual(store.items.count, 20)
                XCTAssertEqual(store.pendingRemoval?.deadline, now.addingTimeInterval(10))
                try await NativeUI.waitFor("remaining row fills the removed row", in: content) {
                    guard let next = NativeUI.find(in: content, id: "shelf-item-\(items[3].id)")?.accessibilityFrame?() else { return false }
                    return abs(next.midY - first.midY) < 1
                        && removed.allSatisfy { NativeUI.find(in: content, id: "shelf-item-\($0.id)") == nil }
                }
                let undo = try await NativeUI.waitForElement(in: content, id: "shelf-undo")
                XCTAssertEqual(undo.accessibilityPerformPress?(), true)
                try await NativeUI.waitFor("undo restores both complete rows", in: content) {
                    guard let viewport = NativeUI.find(in: content, id: "shelf-file-scroll")?.accessibilityFrame?() else { return false }
                    return items.prefix(6).allSatisfy { item in
                        guard let frame = NativeUI.find(in: content, id: "shelf-item-\(item.id)")?.accessibilityFrame?() else { return false }
                        return viewport.insetBy(dx: -0.5, dy: -0.5).contains(frame)
                    }
                }
                XCTAssertEqual(store.visibleItems.map(\.id), items.map(\.id))
                XCTAssertNil(store.pendingRemoval)
                XCTAssertEqual(try NativeUI.frame(in: content, id: "shelf-tray"), pane)
                let airDrop = try NativeUI.frame(in: content, id: "shelf-airdrop")
                XCTAssertEqual(airDrop.minY, pane.minY, accuracy: 1)
                XCTAssertEqual(airDrop.maxY, pane.maxY, accuracy: 1)
            }
        }
    }

    private func assertVisible(_ id: String, in window: NSWindow, file: StaticString = #filePath, line: UInt = #line) throws {
        let content = try XCTUnwrap(window.contentView, file: file, line: line)
        let frame = try NativeUI.frame(in: content, id: id, file: file, line: line)
        let visible = window.convertToScreen(content.convert(content.bounds, to: nil))
        XCTAssertTrue(visible.insetBy(dx: -1, dy: -1).contains(frame), "\(id): \(frame) outside window \(visible)", file: file, line: line)
    }
}
