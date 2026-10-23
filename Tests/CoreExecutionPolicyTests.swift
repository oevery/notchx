import AppKit
import XCTest
@testable import NotchX

@MainActor
final class CoreExecutionPolicyTests: XCTestCase {
    func testCoreHostCannotActivateAndHasNoVisibleWindows() {
        XCTAssertEqual(ProcessInfo.processInfo.environment["NOTCHX_UNIT_TEST_HOST"], "1")
        XCTAssertEqual(ProcessInfo.processInfo.environment["NOTCHX_DESKTOP_UI"], "0")
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        XCTAssertFalse(NSApp.isActive)
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible })
    }
}
