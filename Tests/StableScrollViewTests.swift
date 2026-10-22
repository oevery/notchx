import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class StableScrollViewTests: XCTestCase {
    func testOverlayAndLegacyKeepViewportSizeAcrossOverflowThresholds() async throws {
        // Pages scroll vertically; visible two-axis scrollers belong to fixed
        // preview regions. Horizontal navigation intentionally hides indicators.
        for axes in [Axis.Set.vertical, [.horizontal, .vertical]] {
            for style in [NSScroller.Style.overlay, .legacy] {
                let model = ScrollFixtureModel()
                let host = NSHostingView(rootView: ScrollFixture(model: model, axes: axes))
                let window = makeWindow(host)
                defer { window.contentView = nil; window.close() }
                let scroll = try await configuredScroll(in: host)
                scroll.scrollerStyle = style
                try await settleLayout(in: host, scrolls: [scroll])
                XCTAssertEqual(scroll.hasVerticalScroller, axes.contains(.vertical))
                XCTAssertEqual(scroll.hasHorizontalScroller, axes.contains(.horizontal))
                let viewport = scroll.contentView.bounds.size
                for expanded in [true, false, true, false] {
                    withAnimation(.easeInOut(duration: 0.08)) { model.expanded = expanded }
                    try await NativeUI.waitFor("document crosses the overflow threshold", in: host) {
                        let size = scroll.documentView?.bounds.size ?? .zero
                        return axes.contains(.vertical) ? (expanded ? size.height > viewport.height : size.height <= viewport.height)
                            : (expanded ? size.width > viewport.width : size.width <= viewport.width)
                    }
                    let clock = ContinuousClock(), end = clock.now.advanced(by: .milliseconds(120))
                    while clock.now < end {
                        host.layoutSubtreeIfNeeded()
                        XCTAssertEqual(scroll.contentView.bounds.width, viewport.width, accuracy: 0.5, "axes=\(axes), style=\(style), frame=\(scroll.frame)")
                        XCTAssertEqual(scroll.contentView.bounds.height, viewport.height, accuracy: 0.5, "axes=\(axes), style=\(style), frame=\(scroll.frame)")
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(scroll === NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }.first)
                }
            }
        }
    }

    func testHiddenIndicatorsKeepTheFullViewportInBothStyles() async throws {
        for axes in [Axis.Set.horizontal, [.horizontal, .vertical]] {
            let model = ScrollFixtureModel()
            let host = NSHostingView(rootView: ScrollFixture(model: model, axes: axes, showsIndicators: false))
            let window = makeWindow(host)
            defer { window.contentView = nil; window.close() }
            let scroll = try await configuredScroll(in: host, showsIndicators: false)
            for style in [NSScroller.Style.overlay, .legacy] {
                scroll.scrollerStyle = style
                for expanded in [true, false] {
                    model.expanded = expanded
                    await NativeUI.drainMainQueue()
                    host.layoutSubtreeIfNeeded()
                    XCTAssertFalse(scroll.hasVerticalScroller)
                    XCTAssertFalse(scroll.hasHorizontalScroller)
                    XCTAssertEqual(scroll.contentView.bounds.width, scroll.bounds.width, accuracy: 0.5)
                    XCTAssertEqual(scroll.contentView.bounds.height, scroll.bounds.height, accuracy: 0.5)
                }
            }
        }
    }

    func testActualDisclosureKeepsCardWidthAcrossRepeatedExpansionAndCollapse() async throws {
        for style in [NSScroller.Style.overlay, .legacy] {
            let host = NSHostingView(rootView: StableScrollView {
                SettingGroup {
                    SettingDisclosureGroup(title: "Connection diagnostics", identifier: "stable-disclosure-toggle") {
                        Text("Events received").frame(height: 600)
                    }
                }.accessibilityIdentifier("stable-disclosure-card")
            })
            let window = makeWindow(host)
            defer { window.contentView = nil; window.close() }
            let scroll = try await configuredScroll(in: host)
            scroll.scrollerStyle = style
            try await settleLayout(in: host, scrolls: [scroll])
            let viewportWidth = scroll.contentView.bounds.width
            let cardWidth = try NativeUI.frame(in: host, id: "stable-disclosure-card").width
            for expanded in [true, false, true, false] {
                let toggle = try await NativeUI.waitForElement(in: host, id: "stable-disclosure-toggle")
                XCTAssertEqual(toggle.accessibilityPerformPress?(), true)
                try await NativeUI.waitFor("disclosure crosses the scrolling threshold", in: host) {
                    guard let document = scroll.documentView else { return false }
                    return expanded ? document.bounds.height > scroll.contentView.bounds.height
                        : document.bounds.height <= scroll.contentView.bounds.height
                }
                let clock = ContinuousClock(), end = clock.now.advanced(by: .milliseconds(160))
                while clock.now < end {
                    host.layoutSubtreeIfNeeded()
                    XCTAssertEqual(scroll.contentView.bounds.width, viewportWidth, accuracy: 0.5)
                    XCTAssertEqual(try NativeUI.frame(in: host, id: "stable-disclosure-card").width, cardWidth, accuracy: 0.5)
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            let toggle = try await NativeUI.waitForElement(in: host, id: "stable-disclosure-toggle")
            XCTAssertEqual(toggle.accessibilityPerformPress?(), true)
            window.setContentSize(CGSize(width: 420, height: 180))
            try await NativeUI.waitFor("resizing updates the viewport without rebuilding expanded content", in: host) {
                guard let frame = NativeUI.find(in: host, id: "stable-disclosure-card")?.accessibilityFrame?(),
                      let document = scroll.documentView else { return false }
                return scroll.contentView.bounds.width > viewportWidth + 80 && abs(frame.width - scroll.contentView.bounds.width) < 0.5
                    && document.bounds.height > scroll.contentView.bounds.height
            }
            let value: (() -> Any?)? = NativeUI.find(in: host, id: "stable-disclosure-toggle")?.accessibilityValue
            XCTAssertEqual((value?() as? NSNumber)?.intValue, 1)
        }
    }

    func testSettingsSidebarWithQuitAreaAdoptsStableScrollersAcrossResizing() async throws {
        let domain = "app.notchx.tests.sidebar-scroll." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        let navigation = SettingsNavigation.shared, previousPane = navigation.selectedPane
        navigation.selectedPane = .appearance
        defer {
            navigation.selectedPane = previousPane
            preferences.removePersistentDomain(forName: domain)
        }
        let host = NSHostingView(rootView: SettingsView().environmentObject(AppState(preferenceStore: preferences)))
        let window = makeWindow(host, height: 680)
        window.setContentSize(CGSize(width: 960, height: 680))
        defer { window.contentView = nil; window.close() }
        var sidebar: NSScrollView?
        try await NativeUI.waitFor("actual settings sidebar and its bottom quit area", in: host) {
            sidebar = NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }
                .first { abs($0.frame.width - 200) < 0.5 }
            return sidebar != nil && NativeUI.elements(in: host).contains {
                $0.accessibilityRole?() == .button && $0.accessibilityLabel?() == L10n.text("Quit NotchX")
            }
        }
        let scroll = try XCTUnwrap(sidebar)
        try await NativeUI.waitFor("sidebar including its safe area adopts stable scrollers", in: host) {
            !scroll.autohidesScrollers && scroll.hasVerticalScroller && !scroll.hasHorizontalScroller
        }
        for style in [NSScroller.Style.overlay, .legacy] {
            scroll.scrollerStyle = style
            try await settleLayout(in: host, scrolls: [scroll])
            let width = scroll.contentView.bounds.width
            XCTAssertEqual(scroll.scrollerStyle, style)
            if style == .legacy { XCTAssertLessThan(width, scroll.bounds.width) }
            else { XCTAssertEqual(width, scroll.bounds.width, accuracy: 0.5) }
            for height: CGFloat in [560, 900, 560] {
                window.setContentSize(CGSize(width: 960, height: height))
                try await settleLayout(in: host, scrolls: [scroll])
                XCTAssertEqual(scroll.contentView.bounds.width, width, accuracy: 0.5)
                XCTAssertEqual(scroll.scrollerStyle, style)
                XCTAssertFalse(scroll.autohidesScrollers)
                let quit = try XCTUnwrap(NativeUI.elements(in: host).first {
                    $0.accessibilityRole?() == .button && $0.accessibilityLabel?() == L10n.text("Quit NotchX")
                })
                let frame = try XCTUnwrap(quit.accessibilityFrame?())
                let contentFrame = window.convertToScreen(host.convert(host.bounds, to: nil))
                XCTAssertTrue(contentFrame.contains(frame), "The quit button must remain visible below the list")
            }
        }
    }

    func testNativeListAndEditorKeepWidthWhileContentChanges() async throws {
        let model = ScrollFixtureModel()
        let host = NSHostingView(rootView: NativeScrollFixture(model: model))
        let window = makeWindow(host, height: 420)
        defer { window.contentView = nil; window.close() }
        try await NativeUI.waitFor("both native controls adopt stable scrollers", in: host) {
            let scrolls = NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }
            return scrolls.count == 2 && scrolls.allSatisfy { !$0.autohidesScrollers && $0.hasVerticalScroller && !$0.hasHorizontalScroller }
        }
        let scrolls = NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }
        let list = try XCTUnwrap(scrolls.first)
        // SwiftUI reapplies the system style when native control data changes.
        // Forced per-view styles are covered by the actual settings resize test.
        for _ in 0..<2 {
            try await settleLayout(in: host, scrolls: scrolls)
            let widths = scrolls.map { $0.contentView.bounds.width }
            let quitFrame = try NativeUI.frame(in: host, id: "stable-sidebar-quit")
            for expanded in [true, false, true, false] {
                model.text = expanded ? String(repeating: "Editor fixture\n", count: 80) : "Short draft"
                model.expanded = expanded
                try await NativeUI.waitFor("sidebar rows cross the overflow threshold", in: host) {
                    guard let document = list.documentView else { return false }
                    return expanded ? document.bounds.height > list.contentView.bounds.height
                        : document.bounds.height <= list.contentView.bounds.height + 0.5
                }
                try await settleLayout(in: host, scrolls: scrolls)
                for (scroll, width) in zip(scrolls, widths) {
                    XCTAssertEqual(scroll.contentView.bounds.width, width, accuracy: 0.5)
                    XCTAssertEqual(scroll.scrollerStyle, NSScroller.preferredScrollerStyle)
                    XCTAssertFalse(scroll.autohidesScrollers)
                }
                let frame = try NativeUI.frame(in: host, id: "stable-sidebar-quit")
                XCTAssertEqual(frame.minX, quitFrame.minX, accuracy: 0.5)
                XCTAssertEqual(frame.minY, quitFrame.minY, accuracy: 0.5)
            }
        }
    }

    func testNestedScrollViewsKeepTheirOwnAxesAndDetachObservers() async throws {
        let host = NSHostingView(rootView: AnyView(StableScrollView {
            StableScrollView([.horizontal, .vertical]) { Text("Nested preview").frame(width: 800, height: 600) }.frame(height: 120)
        }))
        let window = makeWindow(host)
        defer { window.contentView = nil; window.close() }
        try await NativeUI.waitFor("independent nested scroll configurations", in: host) {
            let scrolls = NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }
            return scrolls.count == 2 && scrolls.allSatisfy { !$0.autohidesScrollers && $0.hasVerticalScroller }
                && scrolls.filter { $0.hasHorizontalScroller }.count == 1
        }
        let scrolls = NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }
        host.rootView = AnyView(Text("Removed"))
        try await NativeUI.waitFor("old scroll views detach", in: host) { scrolls.allSatisfy { $0.window == nil } }
        scrolls.forEach { $0.autohidesScrollers = true }
        await NativeUI.drainMainQueue()
        XCTAssertTrue(scrolls.allSatisfy { $0.autohidesScrollers }, "Detached probes must stop reconfiguring old scroll views")
    }

    private func configuredScroll(in host: NSView, showsIndicators: Bool = true) async throws -> NSScrollView {
        try await NativeUI.waitFor("stable native scroller configuration", in: host) {
            guard let scroll = NativeUI.nativeViews(in: host).compactMap({ $0 as? NSScrollView }).first else { return false }
            return !scroll.autohidesScrollers && (showsIndicators ? scroll.hasVerticalScroller || scroll.hasHorizontalScroller
                : !scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        }
        return try XCTUnwrap(NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }.first)
    }

    private func settleLayout(in host: NSView, scrolls: [NSScrollView]) async throws {
        var previous: [NSRect] = [], stablePasses = 0
        try await NativeUI.waitFor("native scroller style and layout settle", in: host) {
            scrolls.forEach { $0.tile() }
            host.layoutSubtreeIfNeeded()
            let frames = scrolls.flatMap { [$0.frame, $0.contentView.frame] }
            stablePasses = frames == previous ? stablePasses + 1 : 0
            previous = frames
            return stablePasses >= 3
        }
    }

    private func makeWindow<Content: View>(_ host: NSHostingView<Content>, height: CGFloat = 180) -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 320, height: height),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        return window
    }

    private final class ScrollFixtureModel: ObservableObject {
        @Published var expanded = false
        @Published var text = "Short draft"
    }

    private struct ScrollFixture: View {
        @ObservedObject var model: ScrollFixtureModel
        let axes: Axis.Set
        var showsIndicators = true
        var body: some View {
            StableScrollView(axes, showsIndicators: showsIndicators) {
                Text("Scroll fixture").frame(width: axes.contains(.horizontal) ? (model.expanded ? 800 : 100) : nil,
                    height: axes.contains(.vertical) ? (model.expanded ? 600 : 60) : 40)
                    .frame(maxWidth: axes.contains(.horizontal) ? nil : .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct NativeScrollFixture: View {
        @ObservedObject var model: ScrollFixtureModel
        var body: some View {
            VStack {
                List { ForEach(0..<(model.expanded ? 50 : 1), id: \.self) { Text(verbatim: "Row \($0)") } }
                    .listStyle(.sidebar)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        VStack(spacing: 0) {
                            Divider().padding(.horizontal, 12)
                            HStack {
                                Button("Quit NotchX") {}.accessibilityIdentifier("stable-sidebar-quit")
                                    .buttonStyle(.bordered).controlSize(.regular)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 16)
                        }
                    }
                    .stableNativeScrollLayout()
                TextEditor(text: $model.text).stableNativeScrollLayout()
            }
        }
    }
}
