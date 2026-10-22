import SwiftUI
import XCTest
@testable import NotchX

final class SettingsControlsTests: XCTestCase {
    func testDimensionBoundsPreserveExactFractionalValues() {
        XCTAssertEqual(SettingValueBounds.clamped(217.35, in: 140...320), 217.35)
        XCTAssertEqual(SettingValueBounds.clamped(36.75, in: 28...60), 36.75)
    }

    func testDimensionBoundsIncludeBothEndpoints() {
        for range in [140.0...320.0, 28.0...60.0] {
            XCTAssertEqual(SettingValueBounds.clamped(range.lowerBound, in: range), range.lowerBound)
            XCTAssertEqual(SettingValueBounds.clamped(range.upperBound, in: range), range.upperBound)
            XCTAssertEqual(SettingValueBounds.clamped(range.lowerBound - 1, in: range), range.lowerBound)
            XCTAssertEqual(SettingValueBounds.clamped(range.upperBound + 1, in: range), range.upperBound)
        }
    }

    func testInvalidDimensionValuesCannotReachTheSettingsBinding() {
        let range = 140.0...320.0
        XCTAssertEqual(SettingValueBounds.clamped(.nan, in: range), range.lowerBound)
        XCTAssertEqual(SettingValueBounds.clamped(-.infinity, in: range), range.lowerBound)
        XCTAssertEqual(SettingValueBounds.clamped(.infinity, in: range), range.upperBound)
    }

    func testSliderAndNumericEditsShareBoundsWithoutStepRounding() {
        var storedValue = 200.0
        let storage = Binding(get: { storedValue }, set: { storedValue = $0 })
        let bounded = SettingValueBounds.binding(storage, in: 140...320)

        bounded.wrappedValue = 211.25
        XCTAssertEqual(storedValue, 211.25)
        XCTAssertEqual(bounded.wrappedValue, 211.25)
        bounded.wrappedValue = 10
        XCTAssertEqual(storedValue, 140)
        bounded.wrappedValue = 400
        XCTAssertEqual(storedValue, 320)

        // Reading an old out-of-range preference is safe and does not rewrite it.
        storedValue = 100
        XCTAssertEqual(bounded.wrappedValue, 140)
        XCTAssertEqual(storedValue, 100)
    }

    func testNumericDraftCommitsAnExactValueOrClampsAtTheBoundary() {
        let locale = Locale(identifier: "en_US")
        for (draft, expected) in [("217.35", 217.35), ("500", 320.0), ("5", 140.0)] {
            XCTAssertEqual(
                SettingValueBounds.committedValue(from: draft, currentValue: 200, in: 140...320, locale: locale),
                expected
            )
        }
    }

    func testEmptyAndInvalidNumericDraftsRestoreTheCurrentValue() {
        let locale = Locale(identifier: "en_US")
        for draft in ["", "  ", "-", ".", "not a number", "NaN", "Infinity"] {
            XCTAssertEqual(
                SettingValueBounds.committedValue(from: draft, currentValue: 217.35, in: 140...320, locale: locale),
                217.35,
                "Invalid draft: \(draft)"
            )
        }
    }

    func testNumericDraftUsesTheFieldLocale() {
        XCTAssertEqual(
            SettingValueBounds.committedValue(
                from: "217,35", currentValue: 200, in: 140...320, locale: Locale(identifier: "de_DE")
            ),
            217.35
        )
    }

    func testResetDiscardsDirtyDraftEvenWhenTheStoredValueAlreadyEqualsTheDefault() {
        let locale = Locale(identifier: "en_US")
        var draft = SettingNumericDraft()
        draft.synchronize(with: 200, locale: locale)
        draft.edit("250")
        XCTAssertTrue(draft.hasUncommittedEdit)

        // The explicit reset generation synchronizes even when the value stays 200.
        draft.synchronize(with: 200, locale: locale)
        XCTAssertEqual(draft.text, "200")
        XCTAssertFalse(draft.hasUncommittedEdit)
        XCTAssertNil(draft.valueToCommit(currentValue: 200, in: 140...320, locale: locale))
    }

    func testFormattingAnUntouchedDraftDoesNotRoundTheStoredSliderValue() {
        let locale = Locale(identifier: "en_US")
        var draft = SettingNumericDraft()
        draft.synchronize(with: 217.3567, locale: locale)
        XCTAssertEqual(draft.text, "217.36")
        XCTAssertNil(draft.valueToCommit(currentValue: 217.3567, in: 140...320, locale: locale))
    }

    func testRestoreOrUndoGenerationPreventsALateBlurFromCommittingAnOldDraft() {
        let locale = Locale(identifier: "en_US")
        var draft = SettingNumericDraft()
        draft.synchronize(with: 200, locale: locale, resetGeneration: 1)
        draft.edit("300")
        // Restore/Undo can happen before SwiftUI delivers the field's onChange.
        XCTAssertNil(draft.valueToCommit(currentValue: 200, in: 140...320, locale: locale, resetGeneration: 2))
        draft.synchronize(with: 217.3567, locale: locale, resetGeneration: 2)
        XCTAssertNil(draft.valueToCommit(currentValue: 217.3567, in: 140...320, locale: locale, resetGeneration: 2))
        draft.edit("250.25")
        XCTAssertEqual(draft.valueToCommit(currentValue: 217.3567, in: 140...320, locale: locale, resetGeneration: 2), 250.25)
    }

    func testExternalValueChangeRejectsAnOldDraftBeforeViewSynchronization() {
        let locale = Locale(identifier: "en_US")
        var draft = SettingNumericDraft()
        draft.synchronize(with: 13.75, locale: locale)
        draft.edit("22")
        XCTAssertNil(draft.valueToCommit(currentValue: 2.5, in: 1...30, locale: locale))
        draft.synchronize(with: 2.5, locale: locale)
        draft.edit("8.25")
        XCTAssertEqual(draft.valueToCommit(currentValue: 2.5, in: 1...30, locale: locale), 8.25)
        draft.synchronize(with: .nan, locale: locale)
        draft.edit("8.25")
        XCTAssertEqual(draft.valueToCommit(currentValue: .nan, in: 1...30, locale: locale), 8.25)
    }
}
