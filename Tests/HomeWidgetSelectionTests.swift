import XCTest
@testable import NotchX

final class HomeWidgetSelectionTests: XCTestCase {
    func testBuiltInSelectionsRoundTrip() {
        for module in ModuleType.allCases {
            let selection = HomeWidgetSelection.builtIn(module)
            XCTAssertEqual(HomeWidgetSelection(rawValue: selection.rawValue), selection)
        }
    }

    func testRemovedExtensionAndUnknownSelectionsFallBackToNone() {
        for value in ["extension.weather", "builtIn.unknown", "", "none"] {
            XCTAssertEqual(HomeWidgetSelection(rawValue: value), .none)
        }
    }
}
