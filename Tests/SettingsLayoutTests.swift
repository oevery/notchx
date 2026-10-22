import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class SettingsLayoutTests: XCTestCase {
    func testDisclosureClicksOnlyArrowAndTitleAndKeepsNestedControlsIndependent() async throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.setVolatileDomain(arguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            for reduced in [false, true] {
                var clicks = 0
                let host = NSHostingView(rootView: SettingGroup {
                    SettingDisclosureGroup(title: "Connection diagnostics", identifier: "fixture-disclosure") {
                        Button("Check connection") { clicks += 1 }.accessibilityIdentifier("fixture-disclosure-action")
                    }
                }.padding(24).frame(maxHeight: .infinity, alignment: .top)
                    .environment(\.islandMotion, IslandMotion(speed: 2, reduced: reduced, bounce: 0)).notchXLocalized())
                let window = makeWindow(host: host, width: 520)
                defer { window.contentView = nil; window.close() }
                _ = try await NativeUI.waitForElement(in: host, id: "fixture-disclosure")
                let header = try NativeUI.frame(in: host, id: "fixture-disclosure")
                XCTAssertLessThan(header.width, 260, "Trailing space must stay outside the button")
                let value: (() -> Any?)? = NativeUI.find(in: host, id: "fixture-disclosure")?.accessibilityValue
                XCTAssertEqual(NativeUI.find(in: host, id: "fixture-disclosure")?.accessibilityRole?(), .disclosureTriangle)
                XCTAssertEqual((value?() as? NSNumber)?.intValue, 0)
                try NativeUI.click(at: NSPoint(x: header.maxX - 4, y: header.midY), in: window)
                let action = try await NativeUI.waitForElement(in: host, id: "fixture-disclosure-action")
                XCTAssertEqual(action.accessibilityPerformPress?(), true)
                XCTAssertEqual(clicks, 1)
                try NativeUI.click(at: NSPoint(x: window.frame.maxX - 32, y: header.midY), in: window)
                await NativeUI.drainMainQueue()
                let expandedValue: (() -> Any?)? = NativeUI.find(in: host, id: "fixture-disclosure")?.accessibilityValue
                XCTAssertEqual((expandedValue?() as? NSNumber)?.intValue, 1)
                XCTAssertNotNil(NativeUI.find(in: host, id: "fixture-disclosure-action"))
                let expandedHeader = try NativeUI.frame(in: host, id: "fixture-disclosure")
                try NativeUI.click(at: NSPoint(x: expandedHeader.minX + 3, y: expandedHeader.midY), in: window)
                try await NativeUI.waitFor("arrow collapses disclosure", in: host) {
                    NativeUI.find(in: host, id: "fixture-disclosure-action") == nil
                }
            }
        }
    }

    func testDisclosureAnimatesExpansionAndCollapseWithSharedMotion() async throws {
        for reduced in [false, true] {
            let motion = IslandMotion(speed: 0.5, reduced: reduced, bounce: 0)
            let host = NSHostingView(rootView: SettingGroup {
                SettingDisclosureGroup(title: "Connection diagnostics") {
                    Text("Events received").frame(height: 140)
                }
            }.accessibilityIdentifier("fixture-animated-card")
                .fixedSize(horizontal: false, vertical: true).frame(maxHeight: .infinity, alignment: .top)
                .environment(\.islandMotion, motion))
            let window = makeWindow(host: host, width: 520)
            defer { window.contentView = nil; window.close() }
            _ = try await NativeUI.waitForElement(in: host, id: "settings-disclosure-Connection diagnostics")
            let collapsed = try NativeUI.frame(in: host, id: "fixture-animated-card").height
            let header = try NativeUI.frame(in: host, id: "settings-disclosure-Connection diagnostics")
            try NativeUI.click(at: NSPoint(x: header.midX, y: header.midY), in: window)
            var heights: [CGFloat] = []
            let clock = ContinuousClock(), end = clock.now.advanced(by: .milliseconds(400))
            while clock.now < end {
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                heights.append(try NativeUI.frame(in: host, id: "fixture-animated-card").height)
                try await Task.sleep(for: .milliseconds(10))
            }
            let expanded = try XCTUnwrap(heights.last)
            XCTAssertGreaterThan(expanded, collapsed + 100)
            XCTAssertTrue(heights.contains { $0 > collapsed + 1 && $0 < expanded - 1 }, "Expansion should pass through intermediate heights: \(heights)")
            let expandedHeader = try NativeUI.frame(in: host, id: "settings-disclosure-Connection diagnostics")
            try NativeUI.click(at: NSPoint(x: expandedHeader.minX + 3, y: expandedHeader.midY), in: window)
            heights = []
            let collapseEnd = clock.now.advanced(by: .milliseconds(400))
            while clock.now < collapseEnd {
                host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
                heights.append(try NativeUI.frame(in: host, id: "fixture-animated-card").height)
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try XCTUnwrap(heights.last), collapsed, accuracy: 1)
            XCTAssertTrue(heights.contains { $0 > collapsed + 1 && $0 < expanded - 1 }, "Collapse should pass through intermediate heights: \(heights)")
        }
    }

    func testDiagnosticRelativeDatesUseTheSelectedLanguage() async throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.setVolatileDomain(arguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            let date = Date().addingTimeInterval(60)
            let host = NSHostingView(rootView: SettingSupportingText(Text("Next \(date, style: .relative)"))
                .accessibilityIdentifier("next-refresh").notchXLocalized())
            let window = makeWindow(host: host, width: 520)
            defer { window.close() }
            try await settle(host)
            let element = try XCTUnwrap(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "next-refresh" })
            let value: (() -> Any?)? = element.accessibilityValue
            let text = try XCTUnwrap(value?() as? String ?? element.accessibilityLabel?())
            XCTAssertTrue(text.hasPrefix(language == "zh-Hans" ? "距下次刷新：" : "Next refresh: "), text)
        }
    }

    func testUserCalendarNamesStayVerbatimWhileBuiltInCopyChangesLanguage() async throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.setVolatileDomain(arguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            let host = NSHostingView(rootView: SettingGroup {
                SettingRow(title: "Home", description: "Calendar", localizesTitle: false) {
                    SettingSwitch(title: "Home", isOn: .constant(true), localizesTitle: false)
                        .accessibilityIdentifier("verbatim-calendar-switch")
                }
                SettingNote("Calendar", localizesText: false).accessibilityIdentifier("verbatim-source")
                SettingNote("Calendar").accessibilityIdentifier("translated-note")
                SettingSupportingText(verbatim: "Never").accessibilityIdentifier("verbatim-provider")
            }.notchXLocalized())
            let window = makeWindow(host: host, width: 520)
            defer { window.close() }
            try await settle(host)
            let elements = accessibilityElements(in: host)
            func text(_ id: String) throws -> String? {
                let element = try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == id }, id)
                let value: (() -> Any?)? = element.accessibilityValue
                return value?() as? String ?? element.accessibilityLabel?()
            }
            XCTAssertEqual(try text("settings-label-Home"), "Home")
            XCTAssertEqual(try text("verbatim-calendar-switch"), "Home")
            XCTAssertEqual(try text("verbatim-source"), "Calendar")
            XCTAssertEqual(try text("verbatim-provider"), "Never")
            XCTAssertEqual(try text("translated-note"), L10n.text("Calendar"))
            XCTAssertEqual(try text("settings-description-Home"), L10n.text("Calendar"))
            if language == "zh-Hans" { XCTAssertNotEqual(L10n.text("Home"), "Home") }
        }
    }

    func testPageHeaderAndCardRowsKeepTheirSeparateAlignmentEdges() async throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.setVolatileDomain(arguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            for width: CGFloat in [360, 520, 760] {
                let model = SharedControlsModel()
                let host = NSHostingView(rootView: SharedHeaderFixture(model: model).notchXLocalized())
                let window = makeWindow(host: host, width: width)
                defer { window.close() }
                try await settle(host)
                let elements = accessibilityElements(in: host)
                func element(_ id: String) throws -> AnyObject {
                    try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == id }, id)
                }
                let title = try XCTUnwrap(element("settings-page-title").accessibilityFrame?())
                let header = try element("header-switch")
                let headerFrame = try XCTUnwrap(header.accessibilityFrame?())
                let card = try XCTUnwrap(element("fixture-card").accessibilityFrame?())
                let inner = try element("inner-switch")
                let innerFrame = try XCTUnwrap(inner.accessibilityFrame?())
                XCTAssertEqual(title.minX, card.minX, accuracy: 1, language)
                XCTAssertEqual(headerFrame.maxX, card.maxX, accuracy: 1, language)
                XCTAssertGreaterThan(headerFrame.maxX - innerFrame.maxX, 8)
                XCTAssertEqual(headerFrame.height, innerFrame.height, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(title.minX, window.frame.minX)
                XCTAssertLessThanOrEqual(headerFrame.maxX, window.frame.maxX)
                XCTAssertEqual(header.accessibilityPerformPress?(), true)
                try await settle(host)
                XCTAssertFalse(model.moduleEnabled)
                XCTAssertTrue(model.optionEnabled)
            }
        }
    }

    func testPermissionRowsShareActionLayoutWithoutRequestingAccessOnRender() async throws {
        let model = SharedControlsModel()
        let host = NSHostingView(rootView: SharedPermissionFixture(model: model))
        let window = makeWindow(host: host, width: 520)
        defer { window.close() }
        try await settle(host)
        func element(_ id: String) throws -> AnyObject {
            try XCTUnwrap(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == id }, id)
        }
        let grant = try element("permission-grant")
        let open = try element("permission-open")
        let grantFrame = try XCTUnwrap(grant.accessibilityFrame?())
        let openFrame = try XCTUnwrap(open.accessibilityFrame?())
        XCTAssertEqual(grantFrame.maxX, openFrame.maxX, accuracy: 1)
        XCTAssertTrue(model.actions.isEmpty)
        XCTAssertEqual(open.accessibilityPerformPress?(), true)
        XCTAssertEqual(model.actions, ["open"])
        XCTAssertFalse(model.granted)
        XCTAssertEqual(grant.accessibilityPerformPress?(), true)
        try await settle(host)
        XCTAssertEqual(model.actions, ["open", "grant"])
        XCTAssertTrue(model.granted)
        var elements = accessibilityElements(in: host)
        XCTAssertNil(elements.first { $0.accessibilityIdentifier?() == "permission-grant" })
        XCTAssertNil(elements.first { $0.accessibilityIdentifier?() == "permission-open" })
        XCTAssertNotNil(elements.first {
            // Native static text exposes its text as AXValue; disambiguate
            // AppKit's string/number/value protocol overloads explicitly.
            let value: (() -> Any?)? = $0.accessibilityValue
            return value?() as? String == L10n.text("Ready") || $0.accessibilityLabel?() == L10n.text("Ready")
        })
        model.granted = false
        try await settle(host)
        _ = try element("permission-grant")
        elements = accessibilityElements(in: host)
        XCTAssertNotNil(elements.first { $0.accessibilityIdentifier?() == "permission-open" })
        XCTAssertEqual(model.actions, ["open", "grant"])
    }

    func testSharedRowsAlignControlsAndKeepRestoreAtNativeRegularSize() async throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.setVolatileDomain(arguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            for width: CGFloat in [360, 520, 760] {
                let host = NSHostingView(rootView: fixture().notchXLocalized())
                let window = makeWindow(host: host, width: width)
                defer { window.close() }
                try await settle(host)
                let elements = accessibilityElements(in: host)
                let ids = ["fixture-toggle", "fixture-picker", "fixture-number-stepper", "fixture-duration-unit", "fixture-action", "settings-module-restore", "fixture-group-restore"]
                let frames = try ids.map { id in
                    try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == id }?.accessibilityFrame?(), id)
                }
                let right = try XCTUnwrap(frames.first).maxX
                for (id, frame) in zip(ids, frames) {
                    XCTAssertEqual(frame.maxX, right, accuracy: 2, "\(language) \(width) \(id)")
                    XCTAssertGreaterThanOrEqual(frame.minX, window.frame.minX)
                    XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX)
                }
                let slider = try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == "fixture-duration-slider" }?.accessibilityFrame?())
                let editor = try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == "fixture-duration" }?.accessibilityFrame?())
                XCTAssertGreaterThan(slider.width, 0)
                XCTAssertGreaterThanOrEqual(slider.minX, window.frame.minX)
                XCTAssertLessThanOrEqual(slider.maxX, editor.minX - 4)
                XCTAssertEqual(slider.midY, editor.midY, accuracy: 2)
                let labels = elements.filter { $0.accessibilityIdentifier?()?.hasPrefix("settings-label-") == true }
                let labelLeft = try XCTUnwrap(labels.first?.accessibilityFrame?()).minX
                for label in labels {
                    XCTAssertEqual(try XCTUnwrap(label.accessibilityFrame?()).minX, labelLeft, accuracy: 1)
                }
                let restore = try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == "settings-module-restore" }?.accessibilityFrame?())
                let reference = try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == "fixture-reference" }?.accessibilityFrame?())
                XCTAssertEqual(restore.height, reference.height, accuracy: 0.5)

                let disclosure = try XCTUnwrap(elements.first { $0.accessibilityRole?() == .disclosureTriangle })
                XCTAssertEqual(disclosure.accessibilityPerformPress?(), true)
                try await settle(host)
                let expanded = accessibilityElements(in: host)
                let nested = try XCTUnwrap(expanded.first { $0.accessibilityIdentifier?() == "fixture-nested" }?.accessibilityFrame?())
                XCTAssertEqual(nested.maxX, right, accuracy: 2, "Expanded controls must not gain a second inset")
                let nestedLabel = try XCTUnwrap(expanded.first { $0.accessibilityIdentifier?() == "settings-label-Show reading guide" }?.accessibilityFrame?())
                XCTAssertEqual(nestedLabel.minX, labelLeft, accuracy: 1)
            }
        }
    }

    func testNumberRowSupportsDirectEditingBoundsAndNativeStepping() async throws {
        var value = 13.75
        let host = NSHostingView(rootView: SettingNumberRow(title: "Display duration",
            value: Binding(get: { value }, set: { value = $0 }), step: 0.5, range: 1...30, unit: "s", identifier: "duration"))
        let window = makeWindow(host: host, width: 520)
        defer { window.close() }
        try await settle(host)
        let field = try XCTUnwrap(nativeFields(in: host).first)
        XCTAssertEqual(value, 13.75)
        for (input, expected) in [("8.25", 8.25), ("invalid", 8.25), ("", 8.25), ("100", 30.0), ("0", 1.0)] {
            try await edit(input, field: field, window: window, host: host)
            XCTAssertEqual(value, expected, "Input: \(input)")
        }
        let stepper = try XCTUnwrap(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "duration-stepper" })
        _ = stepper.accessibilityPerformDecrement?()
        try await settle(host)
        XCTAssertEqual(value, 1)
        _ = stepper.accessibilityPerformIncrement?()
        try await settle(host)
        XCTAssertEqual(value, 1.5)
        window.close()
        XCTAssertEqual(value, 1.5)
    }

    func testNumericEditorDoesNotCheckTextOrChangeTheSharedEditor() async throws {
        let model = DurationModel(value: 13.75)
        let host = NSHostingView(rootView: DurationFixture(model: model))
        let window = makeWindow(host: host, width: 520)
        defer { window.close() }
        try await settle(host)
        let field = try XCTUnwrap(nativeFields(in: host).first)
        let shared = try XCTUnwrap(window.fieldEditor(true, for: nil) as? NSTextView)
        let checkingTypes = shared.enabledTextCheckingTypes
        let completion = shared.isAutomaticTextCompletionEnabled
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertFalse(editor === shared)
        XCTAssertTrue(editor.isFieldEditor)
        XCTAssertEqual(editor.enabledTextCheckingTypes, 0)
        XCTAssertFalse(editor.isAutomaticTextCompletionEnabled)
        editor.insertText("8.25", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        try await settle(host)
        XCTAssertEqual(model.value, 13.75)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(host)
        XCTAssertEqual(model.value, 8.25)
        XCTAssertEqual(shared.enabledTextCheckingTypes, checkingTypes)
        XCTAssertEqual(shared.isAutomaticTextCompletionEnabled, completion)

        model.disabled = true
        try await settle(host)
        XCTAssertFalse(field.isEnabled)
    }

    func testNumericEditorCommitsWithReturnAndTab() async throws {
        var firstValue = 13.75
        var secondValue = 3.0
        let host = NSHostingView(rootView: VStack {
            SettingSliderNumberRow(title: "Display duration", value: Binding(get: { firstValue }, set: { firstValue = $0 }), range: 1...30, unit: "s")
            SettingNumberRow(title: "Countdown", value: Binding(get: { secondValue }, set: { secondValue = $0 }), step: 1, range: 0...10, unit: "s")
        })
        let window = makeWindow(host: host, width: 520)
        defer { window.close() }
        try await settle(host)
        let fields = nativeFields(in: host)
        XCTAssertEqual(fields.count, 2)
        let first = try XCTUnwrap(fields.first)
        let second = try XCTUnwrap(fields.last)
        XCTAssertTrue(window.makeFirstResponder(first))
        var editor = try XCTUnwrap(first.currentEditor() as? NSTextView)
        editor.insertText("9.75", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertNewline(nil)
        try await settle(host)
        XCTAssertEqual(firstValue, 9.75)
        XCTAssertTrue(window.makeFirstResponder(first))
        editor = try XCTUnwrap(first.currentEditor() as? NSTextView)
        editor.insertText("11.25", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        editor.insertTab(nil)
        try await settle(host)
        XCTAssertEqual(firstValue, 11.25)
        XCTAssertNotNil(second.currentEditor())
        XCTAssertEqual(secondValue, 3)
    }

    func testDurationSliderAndEditorShareExactValuesAndBounds() async throws {
        let model = DurationModel(value: 13.75)
        let host = NSHostingView(rootView: DurationFixture(model: model))
        let window = makeWindow(host: host, width: 520)
        defer { window.close() }
        try await settle(host)
        let field = try XCTUnwrap(nativeFields(in: host).first)
        let slider = try XCTUnwrap(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "duration-slider" })
        XCTAssertEqual(model.value, 13.75)
        XCTAssertEqual(model.writes, 0)
        XCTAssertFalse(accessibilityElements(in: host).contains { $0.accessibilityRole?() == .incrementor })
        for (input, expected) in [("8.25", 8.25), ("invalid", 8.25), ("", 8.25), ("100", 30.0), ("0", 1.0)] {
            try await edit(input, field: field, window: window, host: host)
            XCTAssertEqual(model.value, expected, "Input: \(input)")
        }
        for expected in [13.75, 1, 30] {
            move(slider, to: expected)
            try await settle(host)
            XCTAssertEqual(model.value, expected, accuracy: 0.000001)
            XCTAssertEqual(field.stringValue, expected.formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US"))))
        }
        model.value = 35
        try await settle(host)
        XCTAssertEqual(model.value, 35, "Browsing must not rewrite an old out-of-range value")
        move(slider, to: 30)
        try await settle(host)
        XCTAssertEqual(model.value, 30, "An explicit slider action must commit the bounded value")
        let writes = model.writes
        window.close()
        XCTAssertEqual(model.writes, writes)
    }

    func testCommonDurationRangeKeepsFullNumericInputAndStableExpandedScale() async throws {
        let model = DurationModel(value: 2.5)
        let host = NSHostingView(rootView: DurationFixture(model: model, commonRange: 1...5))
        let window = makeWindow(host: host, width: 520)
        defer { window.close() }
        try await settle(host)
        let field = try XCTUnwrap(nativeFields(in: host).first)
        let slider = try XCTUnwrap(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "duration-slider" })
        XCTAssertEqual(model.value, 2.5)
        XCTAssertEqual(model.writes, 0)
        move(slider, to: 3, in: 1...5)
        try await settle(host)
        XCTAssertEqual(model.value, 3, accuracy: 0.000001)

        try await edit("13.7567", field: field, window: window, host: host)
        XCTAssertEqual(model.value, 13.7567, accuracy: 0.000001)
        for value in [7.37835, 4.189175, 13.7567] {
            move(slider, to: value, in: 1...13.7567)
            try await settle(host)
            XCTAssertEqual(model.value, value, accuracy: 0.000001, "Moving inward must not rescale subsequent actions")
        }
        try await edit("100", field: field, window: window, host: host)
        XCTAssertEqual(model.value, 30)
        try await edit("2.5", field: field, window: window, host: host)
        move(slider, to: 15.5, in: 1...30)
        try await settle(host)
        XCTAssertEqual(model.value, 15.5, accuracy: 0.000001)
        try await edit("0", field: field, window: window, host: host)
        XCTAssertEqual(model.value, 1)
        let writes = model.writes
        window.close()
        XCTAssertEqual(model.writes, writes)

        // A new appearance starts with the common range and the current exact value.
        let reopenedHost = NSHostingView(rootView: DurationFixture(model: model, commonRange: 1...5))
        let reopenedWindow = makeWindow(host: reopenedHost, width: 520)
        defer { reopenedWindow.close() }
        try await settle(reopenedHost)
        XCTAssertEqual(model.writes, writes)
        let reopenedSlider = try XCTUnwrap(accessibilityElements(in: reopenedHost).first { $0.accessibilityIdentifier?() == "duration-slider" })
        move(reopenedSlider, to: 3, in: 1...5)
        try await settle(reopenedHost)
        XCTAssertEqual(model.value, 3, accuracy: 0.000001)
    }

    func testLegacyDurationAndRestoreKeepExactValuesWithACommonRange() async throws {
        let model = DurationModel(value: 13.7567)
        let host = NSHostingView(rootView: DurationFixture(model: model, commonRange: 1...5))
        let window = makeWindow(host: host, width: 520)
        defer { window.close() }
        try await settle(host)
        let field = try XCTUnwrap(nativeFields(in: host).first)
        let slider = try XCTUnwrap(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "duration-slider" })
        XCTAssertEqual(model.value, 13.7567)
        XCTAssertEqual(model.writes, 0)
        XCTAssertTrue(window.makeFirstResponder(field))
        setDraft("21", field: field)
        move(slider, to: 13.7567, in: 1...13.7567)
        try await settle(host)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(host)
        XCTAssertEqual(model.value, 13.7567)
        for restored in [2.5, 13.7567] {
            XCTAssertTrue(window.makeFirstResponder(field))
            setDraft("25", field: field)
            model.generation += 1
            model.value = restored
            try await settle(host)
            XCTAssertTrue(window.makeFirstResponder(nil))
            try await settle(host)
            XCTAssertEqual(model.value, restored)
        }
        move(slider, to: 7.37835, in: 1...13.7567)
        try await settle(host)
        XCTAssertEqual(model.value, 7.37835, accuracy: 0.000001)
    }

    func testSettingsDescriptionsMatchTwelvePointTextInBothLanguages() async throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for language in ["zh-Hans", "en"] {
            UserDefaults.standard.setVolatileDomain(arguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            let host = NSHostingView(rootView: VStack {
                SettingToggleRow(title: "Accessibility", description: "Granted", isOn: .constant(true))
                SettingRestoreRow(description: "Granted", buttonTitle: "Restore Module Defaults…") {}
                SettingNote("Granted").accessibilityIdentifier("supporting-note")
                Text(L10n.text("Granted")).font(.system(size: 12)).accessibilityIdentifier("reference-12pt")
                Text(L10n.text("Granted")).font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 10)
                    .accessibilityIdentifier("reference-note-12pt")
            })
            let window = makeWindow(host: host, width: 760)
            defer { window.close() }
            try await settle(host)
            let elements = accessibilityElements(in: host)
            func height(_ id: String) throws -> CGFloat {
                try XCTUnwrap(elements.first { $0.accessibilityIdentifier?() == id }?.accessibilityFrame?()).height
            }
            for id in ["settings-description-Accessibility", "settings-description-Restore settings"] {
                XCTAssertEqual(try height(id), try height("reference-12pt"), accuracy: 0.5, language)
            }
            XCTAssertEqual(try height("supporting-note"), try height("reference-note-12pt"), accuracy: 0.5, language)
        }
    }

    func testSliderAndRestoreInvalidateThePreviousInputDraft() async throws {
        let model = DurationModel(value: 13.75)
        let host = NSHostingView(rootView: DurationFixture(model: model))
        let window = makeWindow(host: host, width: 520)
        defer { window.close() }
        try await settle(host)
        let field = try XCTUnwrap(nativeFields(in: host).first)
        let slider = try XCTUnwrap(accessibilityElements(in: host).first { $0.accessibilityIdentifier?() == "duration-slider" })
        XCTAssertTrue(window.makeFirstResponder(field))
        setDraft("21", field: field)
        move(slider, to: 13.75)
        try await settle(host)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(host)
        XCTAssertEqual(model.value, 13.75, accuracy: 0.000001)

        XCTAssertTrue(window.makeFirstResponder(field))
        setDraft("22.5", field: field)
        move(slider, to: 7.25)
        try await settle(host)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(host)
        XCTAssertEqual(model.value, 7.25, accuracy: 0.000001)

        // Restoring the already-selected default must still discard a dirty draft.
        model.value = 2.5
        try await settle(host)
        XCTAssertTrue(window.makeFirstResponder(field))
        setDraft("25", field: field)
        model.generation += 1
        model.value = 2.5
        try await settle(host)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(host)
        XCTAssertEqual(model.value, 2.5)

        // Undo can restore an arbitrary old fraction without a later blur rewriting it.
        XCTAssertTrue(window.makeFirstResponder(field))
        setDraft("29", field: field)
        model.generation += 1
        model.value = 13.75
        try await settle(host)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(host)
        XCTAssertEqual(model.value, 13.75)
    }

    func testWidthChangesKeepTheSameNumericEditorAndUncommittedInput() async throws {
        var value = 13.75
        let host = NSHostingView(rootView: SettingSliderNumberRow(title: "Display duration",
            value: Binding(get: { value }, set: { value = $0 }), range: 1...30, unit: "s"))
        let window = makeWindow(host: host, width: 520)
        defer { window.close() }
        try await settle(host)
        let field = try XCTUnwrap(nativeFields(in: host).first)
        XCTAssertTrue(window.makeFirstResponder(field))
        setDraft("9.75", field: field)
        try await settle(host)
        XCTAssertEqual(value, 13.75)
        window.setContentSize(NSSize(width: 360, height: 760))
        try await settle(host)
        XCTAssertTrue(nativeFields(in: host).first === field)
        XCTAssertEqual(field.currentEditor()?.string ?? field.stringValue, "9.75")
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(host)
        XCTAssertEqual(value, 9.75)
    }

    private func fixture() -> some View {
        VStack(spacing: 16) {
            SettingGroup {
                SettingToggleRow(title: "Volume changes", isOn: .constant(true), identifier: "fixture-toggle")
                SettingPickerRow(title: "Location mode", selection: .constant(false), identifier: "fixture-picker") {
                    Text("Current location").tag(false)
                    Text("Selected city").tag(true)
                }
                SettingNumberRow(title: "Display duration", value: .constant(13.75), step: 0.5, range: 1...30, unit: "s", identifier: "fixture-number")
                SettingSliderNumberRow(title: "Display duration", value: .constant(13.75), range: 1...30, unit: "s", identifier: "fixture-duration")
                SettingActionRow(title: "Location access", buttonTitle: "Grant Access", identifier: "fixture-action") {}
                SettingDisclosureGroup(title: "Advanced animation settings") {
                    SettingToggleRow(title: "Show reading guide", isOn: .constant(true), identifier: "fixture-nested")
                }
            }
            ModuleRestoreDefaultsRow(action: {})
            SettingGroup {
                SettingRestoreRow(buttonTitle: "Restore Group Defaults", identifier: "fixture-group-restore", undo: {}) {}
            }
            Button(L10n.text("Restore Module Defaults…")) {}.buttonStyle(.bordered).controlSize(.regular)
                .accessibilityIdentifier("fixture-reference")
        }.padding(24)
    }

    private func edit<Content: View>(_ text: String, field: NSTextField, window: NSWindow, host: NSHostingView<Content>) async throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        setDraft(text, field: field)
        try await settle(host)
        XCTAssertTrue(window.makeFirstResponder(nil))
        try await settle(host)
    }

    private func setDraft(_ text: String, field: NSTextField) {
        field.stringValue = text
        field.currentEditor()?.string = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func makeWindow<Content: View>(host: NSHostingView<Content>, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 760), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func settle<Content: View>(_ host: NSHostingView<Content>) async throws {
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
    }

    private func nativeFields(in root: NSView) -> [NSTextField] {
        (root as? NSTextField).map { [$0] } ?? root.subviews.flatMap(nativeFields)
    }

    private func move(_ slider: AnyObject, to value: Double, in range: ClosedRange<Double> = 1...30) {
        let minimum = (slider.accessibilityMinValue?() as? NSNumber)?.doubleValue ?? 1
        let maximum = (slider.accessibilityMaxValue?() as? NSNumber)?.doubleValue ?? 30
        slider.setAccessibilityValue?(NSNumber(value: minimum + (value - range.lowerBound) / (range.upperBound - range.lowerBound) * (maximum - minimum)))
    }

    private final class SharedControlsModel: ObservableObject {
        @Published var moduleEnabled = true
        @Published var optionEnabled = true
        @Published var granted = false
        var actions: [String] = []
    }

    private struct SharedHeaderFixture: View {
        @ObservedObject var model: SharedControlsModel
        var body: some View {
            VStack(spacing: 16) {
                SettingPageHeader(title: L10n.text("Teleprompter")) {
                    SettingSwitch(title: "Enable module", isOn: $model.moduleEnabled)
                        .accessibilityIdentifier("header-switch")
                }
                SettingGroup {
                    SettingToggleRow(title: "Show reading guide", isOn: $model.optionEnabled, identifier: "inner-switch")
                }.accessibilityIdentifier("fixture-card")
            }.padding(24)
        }
    }

    private struct SharedPermissionFixture: View {
        @ObservedObject var model: SharedControlsModel
        var body: some View {
            SettingPermissionRow(title: "Word Tracking permissions", isGranted: model.granted, grantedTitle: "Ready") {
                Button(L10n.text("Grant Access")) { model.actions.append("grant"); model.granted = true }
                    .accessibilityIdentifier("permission-grant")
                Button(L10n.text("Open Settings")) { model.actions.append("open") }
                    .accessibilityIdentifier("permission-open")
            }
        }
    }

    private final class DurationModel: ObservableObject {
        @Published var value: Double { didSet { writes += 1 } }
        @Published var generation = 0
        @Published var disabled = false
        private(set) var writes = 0
        init(value: Double) { self.value = value }
    }

    private struct DurationFixture: View {
        @ObservedObject var model: DurationModel
        var commonRange: ClosedRange<Double>? = nil
        var body: some View {
            SettingSliderNumberRow(title: "Display duration", value: $model.value,
                range: 1...30, commonRange: commonRange, unit: "s", identifier: "duration")
                .environment(\.settingResetGeneration, model.generation)
                .environment(\.locale, Locale(identifier: "en_US"))
                .disabled(model.disabled)
        }
    }

    private func accessibilityElements(in root: Any, depth: Int = 0) -> [AnyObject] {
        guard depth < 30 else { return [] }
        let element = root as AnyObject
        return [element] + (element.accessibilityChildren?() ?? []).flatMap { accessibilityElements(in: $0, depth: depth + 1) }
    }
}
