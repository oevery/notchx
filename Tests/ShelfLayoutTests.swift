import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class ShelfLayoutTests: XCTestCase {
    private func withShelf(count: Int = 100, width: CGFloat = 578, height: CGFloat = ShelfGridLayout.contentHeight,
                           animationObservation: ShelfAnimationObservation? = nil,
                           _ body: (ShelfStore, AppState, NSView, IslandPanel, [ShelfItem]) async throws -> Void) async throws {
        let domain = "app.notchx.tests.shelf-layout.\(UUID())"
        let preferences = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: preferences)
        state.presentFullExpandedModule(.shelf)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exports = ShelfExportCoordinator(cache: ShelfExportCache(root: root.appendingPathComponent("exports")))
        let store = ShelfStore(preferences: preferences, managedRoot: root, exports: exports, appState: state)
        store.setEnabled(true)
        let items = (0..<count).map { index in
            ShelfItem(kind: .text, displayName: "\(index) 中英文长文件名称 A long document name with multiple words.pdf",
                      textValue: "sample-\(index)", addedAt: Date(timeIntervalSince1970: Double(10_000 - index)))
        }
        store.add(items)
        let host = NSHostingView(rootView: ShelfAnimationObservedContent(shelf: store, observation: animationObservation)
            .environmentObject(state).environment(\.colorScheme, .dark).notchXLocalized())
        let window = IslandPanel()
        window.isReleasedWhenClosed = false
        window.setFrame(NSRect(x: 100, y: 100, width: width, height: height), display: false)
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.makeFirstResponder(nil)
            window.contentView = nil
            window.close()
            store.setEnabled(false)
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            preferences.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await NativeUI.waitForElement(in: host, id: "shelf-airdrop")
        try await body(store, state, host, window, items)
    }

    func testHundredItemsScrollVerticallyToLastRowWithoutMovingAirDropOrToolbar() async throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.setVolatileDomain(arguments.merging([L10n.preferenceKey: language]) { _, value in value },
                                                   forName: UserDefaults.argumentDomain)
            try await withShelf { _, _, host, window, items in
                _ = try await NativeUI.waitForElement(in: host, id: "shelf-file-scroll")
                let scroll = try XCTUnwrap(NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }.first)
                let document = try XCTUnwrap(scroll.documentView)
                let airDrop = try NativeUI.frame(in: host, id: "shelf-airdrop")
                let toolbar = try NativeUI.frame(in: host, id: "shelf-toolbar")
                let tray = try NativeUI.frame(in: host, id: "shelf-tray")
                XCTAssertLessThanOrEqual(airDrop.maxX + 8, tray.minX, language)
                XCTAssertLessThanOrEqual(tray.maxX, window.frame.maxX + 0.5, language)
                XCTAssertGreaterThan(scroll.contentSize.height, 2 * ShelfGridLayout.itemHeight, language)
                XCTAssertGreaterThan(document.bounds.height, scroll.contentSize.height, language)
                XCTAssertLessThanOrEqual(document.bounds.width, scroll.contentSize.width + 1, language)
                let first = try NativeUI.frame(in: host, id: "shelf-item-\(items[0].id)")
                let second = try NativeUI.frame(in: host, id: "shelf-item-\(items[1].id)")
                let nextRow = try NativeUI.frame(in: host, id: "shelf-item-\(items[3].id)")
                XCTAssertEqual(first.midY, second.midY, accuracy: 1)
                XCTAssertLessThan(nextRow.midY, first.midY - 80)

                // Use AppKit's public scrolling boundary. A windowless CGEvent
                // depends on unrelated event-loop state and is not a reliable
                // substitute for physical mouse/trackpad acceptance.
                document.scroll(NSPoint(x: 0, y: 40))
                try await NativeUI.waitFor("native scrolling moves shelf content", in: host) { scroll.contentView.bounds.minY > 0 }
                // Lazy rows refine the document height as they are realized.
                // Keep scrolling to its current end rather than assuming the
                // initial height estimate is the final bottom offset.
                repeat {
                    let previous = scroll.contentView.bounds.minY
                    document.scroll(NSPoint(x: 0, y: document.bounds.maxY - scroll.contentSize.height))
                    try await NativeUI.waitFor("scroll advances toward the current bottom", in: host) {
                        scroll.contentView.bounds.minY > previous
                            || scroll.contentView.bounds.maxY >= document.bounds.maxY - 0.5
                    }
                } while scroll.contentView.bounds.maxY < document.bounds.maxY - 0.5
                try await NativeUI.waitFor("last shelf row becomes visible", in: host) {
                    guard let last = NativeUI.find(in: host, id: "shelf-item-\(items.last!.id)")?.accessibilityFrame?() else { return false }
                    let visible = scroll.convert(scroll.contentView.frame, to: nil)
                    return window.convertToScreen(visible).contains(last)
                }
                XCTAssertEqual(try NativeUI.frame(in: host, id: "shelf-airdrop"), airDrop)
                XCTAssertEqual(try NativeUI.frame(in: host, id: "shelf-toolbar"), toolbar)
            }
        }
    }

    func testGridKeyboardRangeRemovalAndUndoPreserveItemsAndScrollToFocus() async throws {
        try await withShelf(count: 30, height: 270) { store, _, host, window, items in
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-file-scroll")
            let scroll = try XCTUnwrap(NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }.first)
            try postKey(124, to: window) // first item
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-remove-selected")
            try postKey(125, to: window) // same column, second row (index 3)
            try postKey(125, modifiers: .shift, to: window) // extend to index 6
            try await NativeUI.waitFor("keyboard focus scrolls into view", in: host) { scroll.contentView.bounds.minY > 0 }
            try postKey(51, to: window)
            try await NativeUI.waitFor("only the grid keyboard range is removed", in: host) { store.visibleItems.count == 26 }
            XCTAssertEqual(store.pendingRemoval?.itemIDs, Set(items[3...6].map(\.id)))
            let undo = try await NativeUI.waitForElement(in: host, id: "shelf-undo")
            XCTAssertEqual(undo.accessibilityPerformPress?(), true)
            try await NativeUI.waitFor("undo restores all shelf items", in: host) { store.visibleItems.count == 30 }
            XCTAssertEqual(Set(store.visibleItems.map(\.id)), Set(items.map(\.id)))
        }
    }

    func testSearchRetainsMatchingSelectionAndFeedbackDoesNotShrinkViewport() async throws {
        try await withShelf(count: 20, width: 498, height: 270) { store, _, host, window, items in
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-file-scroll")
            let before = try NativeUI.frame(in: host, id: "shelf-file-scroll")
            let imported = expectation(description: "import feedback")
            XCTAssertTrue(store.handleDrop(providers: [NSItemProvider(object: "new import" as NSString)]) { _ in imported.fulfill() })
            await fulfillment(of: [imported], timeout: 3)
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-import-results")
            XCTAssertEqual(try NativeUI.frame(in: host, id: "shelf-file-scroll"), before)
            try postKey(0, modifiers: .command, to: window)
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-remove-selected")
            XCTAssertEqual(try NativeUI.frame(in: host, id: "shelf-file-scroll"), before, "Selection must not add a row above the files")
            let field = try XCTUnwrap(NativeUI.nativeViews(in: host).compactMap { $0 as? NSTextField }.first)
            field.stringValue = items[12].displayName
            field.sendAction(field.action, to: field.target)
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            try await NativeUI.waitFor("filter removes nonmatching cards", in: host) {
                NativeUI.find(in: host, id: "shelf-item-\(items[12].id)") != nil
                    && NativeUI.find(in: host, id: "shelf-item-\(items[0].id)") == nil
            }
            let remove = try await NativeUI.waitForElement(in: host, id: "shelf-remove-selected")
            XCTAssertEqual(remove.accessibilityPerformPress?(), true)
            try await NativeUI.waitFor("filtered removal affects only the match", in: host) { store.visibleItems.count == 20 }
            XCTAssertEqual(store.pendingRemoval?.itemIDs, [items[12].id])
        }
    }

    func testResizeUpdatesKeyboardRowsAndRetainsSelection() async throws {
        try await withShelf(count: 12, height: 270) { store, _, host, window, items in
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-file-scroll")
            let scroll = try XCTUnwrap(NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }.first)
            try postKey(124, to: window)
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-remove-selected")
            try postKey(125, to: window) // index 3 in the three-column grid
            try await NativeUI.waitFor("selection reaches the second row before resize", in: host) { scroll.contentView.bounds.minY > 0 }
            window.setContentSize(NSSize(width: 498, height: 270))
            try await NativeUI.waitFor("grid reflows to two columns", in: host) {
                guard let first = NativeUI.find(in: host, id: "shelf-item-\(items[0].id)")?.accessibilityFrame?(),
                      let third = NativeUI.find(in: host, id: "shelf-item-\(items[2].id)")?.accessibilityFrame?() else { return false }
                return first.midY > third.midY + 80
            }
            try postKey(125, to: window) // retained index 3 + two columns -> index 5
            try postKey(51, to: window)
            try await NativeUI.waitFor("resized grid removes the focused item", in: host) { store.pendingRemoval != nil }
            XCTAssertEqual(store.pendingRemoval?.itemIDs, [items[5].id])
        }
    }

    func testRemovingLastItemKeepsBothDropPanesAndUndoAvailable() async throws {
        try await withShelf(count: 1) { store, _, host, window, items in
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-file-scroll")
            try postKey(0, modifiers: .command, to: window)
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-remove-selected")
            try postKey(51, to: window)
            let undo = try await NativeUI.waitForElement(in: host, id: "shelf-undo")
            XCTAssertTrue(store.visibleItems.isEmpty)
            let left = try NativeUI.frame(in: host, id: "shelf-airdrop")
            let right = try NativeUI.frame(in: host, id: "shelf-tray")
            XCTAssertGreaterThan(right.height, 200)
            XCTAssertLessThan(left.maxX, right.minX)
            XCTAssertEqual(left.minY, right.minY, accuracy: 1)
            XCTAssertEqual(left.maxY, right.maxY, accuracy: 1)
            XCTAssertEqual(undo.accessibilityPerformPress?(), true)
            _ = try await NativeUI.waitForElement(in: host, id: "shelf-item-\(items[0].id)")
            XCTAssertEqual(store.visibleItems.map(\.id), [items[0].id])
        }
    }

    func testUndoInterruptsRenderedRemovalAndRestoresCardsAfterBothAnimationsFinish() async throws {
        for reduced in [false, true] {
            let observation = ShelfAnimationObservation()
            try await withShelf(count: 12, animationObservation: observation) { store, state, host, _, items in
                state.reduceMotion = reduced
                _ = try await NativeUI.waitForElement(in: host, id: "shelf-file-scroll")
                let pane = try NativeUI.frame(in: host, id: "shelf-tray")
                let didUndo = expectation(description: "undo after removal was rendered")
                let removal = observation.removal
                observation.onRemovalCommitted = { [weak host] in
                    guard let host else { XCTFail("Shelf host disappeared"); return }
                    XCTAssertFalse(removal.isFinished, "Undo must precede actual animation completion; reduced=\(reduced)")
                    let undo = NativeUI.find(in: host, id: "shelf-undo")
                    XCTAssertNotNil(undo)
                    XCTAssertEqual(undo?.accessibilityPerformPress?(), true)
                    didUndo.fulfill()
                }
                defer { observation.onRemovalCommitted = nil; observation.isArmed = false }
                observation.isArmed = true
                store.requestRemoval(Array(items.prefix(3)))
                await fulfillment(of: [didUndo], timeout: 3)
                try await NativeUI.waitFor("interrupted removal and restoration both finish", in: host) {
                    observation.removal.isFinished && observation.restoration.isFinished
                }
                XCTAssertNil(store.pendingRemoval)
                XCTAssertEqual(store.visibleItems.map(\.id), items.map(\.id))
                let viewport = try NativeUI.frame(in: host, id: "shelf-file-scroll")
                for item in items.prefix(6) {
                    XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(try NativeUI.frame(in: host, id: "shelf-item-\(item.id)")))
                }
                XCTAssertEqual(try NativeUI.frame(in: host, id: "shelf-tray"), pane)
            }
        }
    }

    func testHostUsesShelfHeightOnlyForEnabledShelfAndCapsToScreenBudget() {
        let domain = "app.notchx.tests.shelf-size.\(UUID())"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: preferences)
        defer { state.cancelAutoDismiss(); state.cancelFullExpandedDismiss() }
        let normal = state.contentSize(for: .fullExpanded)
        state.presentFullExpandedModule(.shelf)
        XCTAssertGreaterThan(state.contentSize(for: .fullExpanded).height, normal.height + 150)
        XCTAssertEqual(state.contentSize(for: .compact), Constants.nonNotchCompactSize)
        XCTAssertEqual(state.contentSize(for: .expanded), Constants.expandedSize)
        state.selectFullExpandedTab(.home)
        XCTAssertEqual(state.contentSize(for: .fullExpanded), normal)
        state.fullExpandedSelectedTab = .module(.builtIn(.shelf))
        state.shelfEnabled = false
        XCTAssertEqual(state.contentSize(for: .fullExpanded), normal)
        for inline in [false, true] {
            XCTAssertLessThanOrEqual(FullExpandedLayout.shelfContentHeight(inlineToolbar: inline, availableHeight: 240), 240)
            XCTAssertGreaterThan(FullExpandedLayout.shelfContentHeight(inlineToolbar: inline, availableHeight: 900), 300)
        }
        state.shelfEnabled = true
        state.updatePresentationContext(screen: NSScreen.main)
        if let screen = NSScreen.main {
            XCTAssertLessThanOrEqual(state.windowSize(for: .fullExpanded).height, screen.frame.maxY - screen.visibleFrame.minY)
        }
    }

    private func postKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags = [], to window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        NSApp.postEvent(event, atStart: false)
    }

}

@MainActor
private final class ShelfAnimationObservation {
    let removal = AnimationCompletionFlag()
    let restoration = AnimationCompletionFlag()
    var isArmed = false
    var onRemovalCommitted: (() -> Void)?
}

/// Observe the rendered transaction without changing production timing or
/// adding an animation. The outer onChange runs after the Shelf subtree updates.
private struct ShelfAnimationObservedContent: View {
    @ObservedObject var shelf: ShelfStore
    let observation: ShelfAnimationObservation?

    var body: some View {
        ShelfFullExpandedView(shelf: shelf)
            .transaction(value: shelf.pendingRemoval?.itemIDs) { transaction in
                guard let observation, observation.isArmed else { return }
                let completion = shelf.pendingRemoval == nil ? observation.restoration : observation.removal
                transaction.addAnimationCompletion(criteria: .removed) { completion.finish() }
            }
            .onChange(of: shelf.pendingRemoval?.itemIDs) { _, ids in
                guard ids != nil, let observation else { return }
                DispatchQueue.main.async { observation.onRemovalCommitted?() }
            }
    }
}

/// Record completion synchronously, even if SwiftUI invokes it off MainActor.
private final class AnimationCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    func finish() { lock.lock(); finished = true; lock.unlock() }
}
