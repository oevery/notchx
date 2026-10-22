import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class SettingsPresentationTests: XCTestCase {
    func testShoulderSettingsButtonStaysInsideItsToolbarWithPendingReminders() async throws {
        try await assertSettingsButton(layout: .shoulder, pendingReminder: true)
    }

    func testShoulderSettingsButtonOpensSettingsWithoutPendingReminders() async throws {
        try await assertSettingsButton(layout: .shoulder, pendingReminder: false)
    }

    func testInlineSettingsButtonOpensSettingsWithPendingReminders() async throws {
        try await assertSettingsButton(layout: .inline, pendingReminder: true)
    }

    private func assertSettingsButton(layout: FullExpandedTopBarLayout, pendingReminder: Bool) async throws {
        let domain = "app.notchx.tests.settings-presentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        state.currentState = .fullExpanded
        state.showHomeTab()
        if pendingReminder { state.presentEvent(.calendarReminder) }
        let navigation = SettingsNavigation.shared
        let oldPane = navigation.selectedPane
        navigation.selectedPane = .general
        SettingsWindowController.shared.close()
        let host = NSHostingView(rootView:
            FullExpandedTopBarView(layout: layout, selectedTab: .home, contentWidth: 800, notchGap: 200)
                .environmentObject(state)
                .frame(width: 800, height: 40))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            SettingsWindowController.shared.close()
            navigation.selectedPane = oldPane
            window.close()
            state.cancelAutoDismiss()
            state.cancelFullExpandedDismiss()
            defaults.removePersistentDomain(forName: domain)
        }
        host.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(3)
        while accessibilityElement(in: host, identifier: "island-settings") == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let button = try XCTUnwrap(accessibilityElement(in: host, identifier: "island-settings"))
        let frame = try XCTUnwrap(button.accessibilityFrame?())
        XCTAssertGreaterThan(frame.width, 0)
        // The shoulder bar is clipped inside 40 pt of horizontal padding.
        let rightInset: CGFloat = layout == .shoulder ? 40 : 0
        XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX - rightInset + 0.5)
        XCTAssertEqual(button.accessibilityPerformPress?(), true)
        XCTAssertEqual(SettingsWindowController.shared.window?.isVisible, true)
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertEqual(state.presentationHandoffs.count, 1)
        SettingsWindowController.shared.close()
        XCTAssertTrue(state.presentationHandoffs.isEmpty)
        XCTAssertEqual(state.currentState, .compact, "Closing settings does not force the island back open")
    }

    func testSettingsWindowCanOpenCloseAndReopenThroughTheSharedEntry() {
        let navigation = SettingsNavigation.shared
        let oldPane = navigation.selectedPane
        navigation.selectedPane = .general
        defer { SettingsWindowController.shared.close(); navigation.selectedPane = oldPane }
        AppDelegate.showSettingsWindow()
        let window = SettingsWindowController.shared.window
        XCTAssertNotNil(window?.contentViewController)
        XCTAssertEqual(window?.isVisible, true)
        SettingsWindowController.shared.close()
        XCTAssertEqual(window?.isVisible, false)
        AppDelegate.showSettingsWindow()
        XCTAssertTrue(SettingsWindowController.shared.window === window)
        XCTAssertEqual(window?.isVisible, true)
    }

    private func accessibilityElement(in root: Any, identifier: String) -> AnyObject? {
        let element = root as AnyObject
        if element.accessibilityIdentifier?() == identifier { return element }
        for child in element.accessibilityChildren?() ?? [] {
            if let match = accessibilityElement(in: child, identifier: identifier) { return match }
        }
        return nil
    }
}
