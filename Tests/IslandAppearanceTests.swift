import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class IslandAppearanceTests: XCTestCase {
    func testImportHistoryPopoverUsesIslandAppearanceWithoutChangingOtherWindows() async throws {
        let domain = "app.notchx.tests.popover-appearance.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: preferences)
        state.presentFullExpandedModule(.shelf)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let exports = ShelfExportCoordinator(cache: ShelfExportCache(root: root.appendingPathComponent("exports")))
        let store = ShelfStore(preferences: preferences, managedRoot: root, exports: exports)
        store.setEnabled(true)
        let imported = expectation(description: "import creates history")
        XCTAssertTrue(store.handleDrop(providers: [NSItemProvider(object: "Appearance sample" as NSString)]) { _ in imported.fulfill() })
        await fulfillment(of: [imported], timeout: 3)

        let host = NSHostingView(rootView: ShelfImportFeedbackView(shelf: store)
            .environmentObject(state)
            .environment(\.colorScheme, .dark)
            .frame(width: 600, height: 90).notchXLocalized())
        let window = makeWindow(content: host, size: NSSize(width: 600, height: 90), appearance: .darkAqua)
        let other = makeWindow(content: NSView(), size: NSSize(width: 120, height: 90))
        let oldAppearance = NSApp.appearance?.name
        var popoverWindow: NSWindow?
        defer {
            popoverWindow?.close()
            window.close(); other.close()
            store.setEnabled(false)
            preferences.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        _ = try await NativeUI.waitForElement(in: host, id: "shelf-import-results")
        let button = try XCTUnwrap(NativeUI.find(in: host, id: "shelf-import-results"))
        XCTAssertEqual(button.accessibilityPerformPress?(), true)
        popoverWindow = try await NativeUI.window(containing: "shelf-import-history-title")
        let popover = try XCTUnwrap(popoverWindow)
        try await NativeUI.waitFor("island popover appearance") {
            popover.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        XCTAssertEqual(other.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(NSApp.appearance?.name, oldAppearance)
        XCTAssertTrue(state.isControlInteractionActive)
        state.dismiss()
        XCTAssertEqual(state.currentState, .fullExpanded)
        XCTAssertTrue(popover.isVisible)
        popover.close()
        try await NativeUI.waitFor("import history releases its hold", in: host) { !state.isControlInteractionActive }
    }

    func testIslandPresentationUsesDarkAppearanceWithoutChangingOtherWindows() async throws {
        let domain = "app.notchx.tests.island-appearance.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: preferences)
        let host = NSHostingView(rootView: IslandContainerView().environmentObject(state))
        let window = makeWindow(content: host, size: NSSize(width: 600, height: 180))
        let other = makeWindow(content: NSView(), size: NSSize(width: 120, height: 90))
        let oldAppearance = NSApp.appearance?.name
        defer {
            window.close(); other.close()
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss()
            preferences.removePersistentDomain(forName: domain)
        }
        try await NativeUI.waitFor("dark island appearance", in: host) { window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
        XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua)
        XCTAssertEqual(other.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .aqua)
        XCTAssertEqual(NSApp.appearance?.name, oldAppearance)
    }

    private func makeWindow(content: NSView, size: NSSize, appearance: NSAppearance.Name = .aqua) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 100, y: 100), size: size),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = content
        window.orderFront(nil)
        return window
    }

}
