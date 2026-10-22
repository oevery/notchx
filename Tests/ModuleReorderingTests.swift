import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class ModuleReorderingTests: XCTestCase {
    func testUpstreamDragCallbacksReachTheActualModuleOrderCommand() async throws {
        let domain = "app.notchx.tests.module-drag-wiring.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults, preferenceDomainName: domain)
        let capture = ReorderContextCapture()
        let host = NSHostingView(rootView: ModuleDragWiringHarness(appState: state, capture: capture)
            .environment(\.islandMotion, IslandMotion(speed: 1, reduced: true, bounce: 0)))
        let window = makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        try await NativeUI.waitFor("module drag adapter context", in: host) { capture.context != nil }
        var revision = capture.revision
        try XCTUnwrap(capture.context).startDrag(ModuleType.nowPlaying)
        try await NativeUI.waitFor("module drag started", in: host) {
            capture.revision > revision && capture.context?.isDragged(ModuleType.nowPlaying) == true
        }
        revision = capture.revision
        try XCTUnwrap(capture.context).move(ModuleType.tools, .after)
        var expected = Array(ModuleType.allCases.dropFirst()) + [.nowPlaying]
        try await NativeUI.waitFor("drag callback moves module to end", in: host) {
            capture.revision > revision && state.orderedModules == expected
        }
        XCTAssertEqual(AppState(preferenceStore: defaults).orderedModules, expected)
        revision = capture.revision
        try XCTUnwrap(capture.context).move(ModuleType.shelf, .before)
        expected = [.volumeHUD, .battery, .nowPlaying, .shelf, .connectivity, .calendar, .weather, .notifications, .teleprompter, .agent, .tools]
        try await NativeUI.waitFor("reverse drag callback updates module order", in: host) {
            capture.revision > revision && state.orderedModules == expected
        }
        // Repeated target and cancellation must not perform an extra move or roll back.
        try XCTUnwrap(capture.context).move(ModuleType.shelf, .before)
        try XCTUnwrap(capture.context).resetDragState()
        try await NativeUI.waitFor("module drag cleanup", in: host) { capture.context?.isDragged(ModuleType.nowPlaying) == false }
        XCTAssertEqual(state.orderedModules, expected)
        XCTAssertEqual(AppState(preferenceStore: defaults).orderedModules, expected)
    }

    func testSameModulePageIdentitySwitchesRestoreAndUndoToNewOwner() async throws {
        let domainA = "app.notchx.tests.switch-order.\(UUID().uuidString)"
        let domainB = domainA + ".b"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: domainA))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: domainB))
        defer { defaultsA.removePersistentDomain(forName: domainA); defaultsB.removePersistentDomain(forName: domainB) }
        let stateA = AppState(preferenceStore: defaultsA, preferenceDomainName: domainA)
        let stateB = AppState(preferenceStore: defaultsB, preferenceDomainName: domainB)
        stateA.moveModule(.weather, to: .nowPlaying)
        stateB.moveModule(.shelf, to: .nowPlaying)
        let orderB = stateB.orderedModules
        let owner = SettingsOwnerInput(state: stateA)
        let host = NSHostingView(rootView: SwitchingSettingsHost(owner: owner) { state in
            ModuleSettingsView(appState: state, showDetails: { _ in }).padding(24).notchXLocalized()
        })
        let window = makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        _ = try await NativeUI.waitForElement(in: host, id: "module-row-weather")
        try pressButton("Restore Default Order", in: host)
        try await NativeUI.waitFor("owner A undo", in: host) { self.button("Undo", in: host) != nil }
        XCTAssertEqual(stateA.orderedModules, ModuleType.allCases)
        let savedA = defaultsA.persistentDomain(forName: domainA) ?? [:]

        // No rootView replacement or caller-provided .id: the page occupies the same SwiftUI slot.
        owner.state = stateB
        try await NativeUI.waitFor("owner B rows", in: host) {
            self.row(.shelf, isAbove: .nowPlaying, in: host)
        }
        XCTAssertNil(button("Undo", in: host), "Owner A's undo history must not leak to B")
        try pressButton("Restore Default Order", in: host)
        try await NativeUI.waitFor("owner B restored", in: host) { stateB.orderedModules == ModuleType.allCases }
        try await NativeUI.waitFor("owner B undo", in: host) { self.button("Undo", in: host) != nil }
        try pressButton("Undo", in: host)
        try await NativeUI.waitFor("owner B order undone", in: host) { stateB.orderedModules == orderB }
        XCTAssertEqual(AppState(preferenceStore: defaultsB).orderedModules, orderB)
        XCTAssertEqual(NSDictionary(dictionary: defaultsA.persistentDomain(forName: domainA) ?? [:]), NSDictionary(dictionary: savedA))
        owner.state = stateA
        try await NativeUI.waitFor("owner A rows again", in: host) {
            self.row(.nowPlaying, isAbove: .shelf, in: host)
        }
        XCTAssertNil(button("Undo", in: host))
        XCTAssertEqual(owner.appearances, 1)
    }

    func testSameDetailIdentityDiscardsPendingRestoreAndRestoresOnlyNewOwner() async throws {
        let domainA = "app.notchx.tests.switch-detail.\(UUID().uuidString)"
        let domainB = domainA + ".b"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: domainA))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: domainB))
        defer { defaultsA.removePersistentDomain(forName: domainA); defaultsB.removePersistentDomain(forName: domainB) }
        let stateA = AppState(preferenceStore: defaultsA, preferenceDomainName: domainA)
        let stateB = AppState(preferenceStore: defaultsB, preferenceDomainName: domainB)
        let defaultDuration = stateB.presentationPreferences[.volume].duration
        stateA.presentationPreferences[.volume].duration = 13.75
        stateB.presentationPreferences[.volume].duration = 8.25
        let savedA = defaultsA.persistentDomain(forName: domainA) ?? [:]
        let owner = SettingsOwnerInput(state: stateA)
        let host = NSHostingView(rootView: SwitchingSettingsHost(owner: owner) { state in
            ModuleDetailSettingsView(module: .volumeHUD, appState: state).padding(24).notchXLocalized()
        })
        let window = makeWindow(host: host)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
            window.contentView = nil
            window.close()
        }
        let restoreA = try await NativeUI.waitForElement(in: host, id: "settings-module-restore")
        XCTAssertEqual(restoreA.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("owner A restore confirmation") { window.attachedSheet != nil }
        owner.state = stateB
        try await NativeUI.waitFor("old confirmation discarded", in: host) { window.attachedSheet == nil }
        XCTAssertEqual(stateB.presentationPreferences[.volume].duration, 8.25)
        let restoreB = try await NativeUI.waitForElement(in: host, id: "settings-module-restore")
        XCTAssertEqual(restoreB.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("owner B restore confirmation") { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet?.contentView)
        let confirm = try XCTUnwrap(NativeUI.nativeViews(in: sheet).compactMap { $0 as? NSButton }
            .first { $0.title == L10n.text("Restore Module Defaults") })
        confirm.performClick(nil)
        try await NativeUI.waitFor("owner B module restored", in: host) {
            stateB.presentationPreferences[.volume].duration == defaultDuration && window.attachedSheet == nil
        }
        XCTAssertEqual(AppState(preferenceStore: defaultsB).presentationPreferences[.volume].duration, defaultDuration)
        XCTAssertEqual(stateA.presentationPreferences[.volume].duration, 13.75)
        XCTAssertEqual(NSDictionary(dictionary: defaultsA.persistentDomain(forName: domainA) ?? [:]), NSDictionary(dictionary: savedA))
        XCTAssertEqual(owner.appearances, 1)
    }

    func testModuleOrderCommandUpdatesActualRowsAndPersistsForwardReverseAndEndMoves() async throws {
        for initial in [ModuleType.allCases, Array(ModuleType.allCases.reversed())] {
            let domain = "app.notchx.tests.module-list-command.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            defaults.set(initial.map(\.rawValue).joined(separator: ","), forKey: ModuleOrder.key)
            let state = AppState(preferenceStore: defaults, preferenceDomainName: domain)
            let list = ModuleManagementList(appState: state, showDetails: { _ in })
            let host = NSHostingView(rootView: list.padding(24).notchXLocalized())
            let window = makeWindow(host: host)
            defer { window.contentView = nil; window.close() }
            _ = try await NativeUI.waitForElement(in: host, id: "module-row-nowPlaying")
            var expected = initial
            let count = initial.count
            for (source, insertion) in [
                (0, count), (count - 1, 0), (1, count - 2), (count - 3, 0)
            ] {
                let module = try XCTUnwrap(expected.dropFirst(source).first)
                // Independent oracle: split at the insertion boundary, filtering out the moved identity.
                let before = expected.prefix(insertion).filter { $0 != module }
                let after = expected.dropFirst(insertion).filter { $0 != module }
                expected = before + [module] + after

                // The same business command used by the list's drag adapter.
                state.moveModules(from: IndexSet(integer: source), to: insertion)
                XCTAssertEqual(state.orderedModules, expected)
                try await NativeUI.waitFor("module rows follow the move command", in: host) {
                    let positions = expected.compactMap { module -> CGFloat? in
                        guard let rect = NativeUI.find(in: host, id: "module-row-" + module.rawValue)?.accessibilityFrame?(),
                              rect.height > 0 else { return nil }
                        return rect.midY
                    }
                    return positions.count == expected.count && zip(positions, positions.dropFirst()).allSatisfy { $0 > $1 }
                }
                XCTAssertEqual(AppState(preferenceStore: defaults).orderedModules, expected)
            }
            XCTAssertNotEqual(expected, ModuleType.allCases)
        }
    }

    func testModuleOrderRejectsInvalidAndNoOpMovesWithoutWritingOrder() throws {
        let domain = "app.notchx.tests.module-list-invalid.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults, preferenceDomainName: domain)
        let count = ModuleType.allCases.count
        for (source, destination) in [
            (IndexSet(), 0), (IndexSet([0, 1]), 2), (IndexSet(integer: count), 0),
            (IndexSet(integer: 0), -1), (IndexSet(integer: 0), count + 1),
            (IndexSet(integer: 0), 0), (IndexSet(integer: 0), 1), (IndexSet(integer: count - 1), count)
        ] {
            state.moveModules(from: source, to: destination)
            XCTAssertEqual(state.orderedModules, ModuleType.allCases)
            XCTAssertNil(defaults.persistentDomain(forName: domain)?[ModuleOrder.key])
        }
    }

    func testModulePageUsesInjectedStateForRowsRestoreAndUndoDespiteForeignEnvironment() async throws {
        let domain = "app.notchx.tests.module-page-owner.\(UUID().uuidString)"
        let foreignDomain = domain + ".foreign"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let foreignDefaults = try XCTUnwrap(UserDefaults(suiteName: foreignDomain))
        defer { defaults.removePersistentDomain(forName: domain); foreignDefaults.removePersistentDomain(forName: foreignDomain) }
        let state = AppState(preferenceStore: defaults, preferenceDomainName: domain)
        let foreign = AppState(preferenceStore: foreignDefaults, preferenceDomainName: foreignDomain)
        state.moveModule(.weather, to: .nowPlaying)
        foreign.moveModule(.shelf, to: .nowPlaying)
        let foreignOrder = foreign.orderedModules
        let host = NSHostingView(rootView: ModuleSettingsView(appState: state, showDetails: { _ in })
            .padding(24).environmentObject(foreign).notchXLocalized())
        let window = makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        let row = try await NativeUI.waitForElement(in: host, id: "module-row-weather")
        let down = try XCTUnwrap(row.accessibilityCustomActions?()?.first { $0.name == L10n.text("Move Down") })
        XCTAssertEqual(down.handler?(), true)
        try await NativeUI.waitFor("injected order changes", in: host) { state.orderedModules.first == .nowPlaying }
        let reordered = state.orderedModules
        XCTAssertNotEqual(reordered, ModuleType.allCases)
        let restore = try XCTUnwrap(NativeUI.elements(in: host).first { $0.accessibilityLabel?() == L10n.text("Restore Default Order") })
        XCTAssertEqual(restore.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("injected order restored", in: host) { state.orderedModules == ModuleType.allCases }
        try await NativeUI.waitFor("order undo action", in: host) {
            NativeUI.elements(in: host).contains { $0.accessibilityLabel?() == L10n.text("Undo") }
        }
        let undo = try XCTUnwrap(NativeUI.elements(in: host).first { $0.accessibilityLabel?() == L10n.text("Undo") })
        XCTAssertEqual(undo.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("injected order undone", in: host) { state.orderedModules == reordered }
        XCTAssertEqual(AppState(preferenceStore: defaults).orderedModules, reordered)
        XCTAssertEqual(foreign.orderedModules, foreignOrder)
        XCTAssertEqual(AppState(preferenceStore: foreignDefaults).orderedModules, foreignOrder)
    }

    func testModuleDetailUsesInjectedStateForHeaderAndNestedSettingsDespiteForeignEnvironment() async throws {
        let domain = "app.notchx.tests.module-detail-owner.\(UUID().uuidString)"
        let foreignDomain = domain + ".foreign"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let foreignDefaults = try XCTUnwrap(UserDefaults(suiteName: foreignDomain))
        defer { defaults.removePersistentDomain(forName: domain); foreignDefaults.removePersistentDomain(forName: foreignDomain) }
        let state = AppState(preferenceStore: defaults, preferenceDomainName: domain)
        let foreign = AppState(preferenceStore: foreignDefaults, preferenceDomainName: foreignDomain)
        foreign.volumeHUDEnabled = false
        foreign.presentationPreferences[.volume].enabled = false
        let host = NSHostingView(rootView: ModuleDetailSettingsView(module: .volumeHUD, appState: state)
            .padding(24).environmentObject(foreign).notchXLocalized())
        let window = makeWindow(host: host)
        defer { window.contentView = nil; window.close() }
        let event = try await NativeUI.waitForElement(in: host, id: "event-enabled-volume")
        XCTAssertEqual(event.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("injected nested setting changes", in: host) { !state.presentationPreferences[.volume].enabled }
        let header = try XCTUnwrap(NativeUI.find(in: host, id: "data-annotation-id=module-detail-toggle-volumeHUD"))
        XCTAssertEqual(header.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("injected header changes", in: host) { !state.volumeHUDEnabled }
        XCTAssertFalse(foreign.volumeHUDEnabled)
        XCTAssertFalse(foreign.presentationPreferences[.volume].enabled)
        XCTAssertFalse(AppState(preferenceStore: defaults).volumeHUDEnabled)
    }

    func testSwiftUIRowsKeepActionsControlsAndPersistenceAcrossLanguagesAndWidths() async throws {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain) }
        for (language, width) in [("en", CGFloat(540)), ("en", 740), ("zh-Hans", 540), ("zh-Hans", 740)] {
            UserDefaults.standard.setVolatileDomain(arguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            let domain = "app.notchx.tests.swiftui-reorder.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer { defaults.removePersistentDomain(forName: domain) }
            let state = AppState(preferenceStore: defaults, preferenceDomainName: domain)
            var details: ModuleType?
            let host = NSHostingView(rootView: StableScrollView {
                ModuleSettingsView(appState: state) { details = $0 }.padding(24)
            }.environment(\.islandMotion, IslandMotion(speed: 1, reduced: true, bounce: 0)).notchXLocalized())
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: width, height: 760),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            defer {
                if (testRun?.failureCount ?? 0) > 0 {
                    for element in NativeUI.elements(in: host) {
                        print("SWIFTUI-REORDER-AX", element.accessibilityIdentifier?() as Any,
                              element.accessibilityLabel?() as Any, element.accessibilityFrame?() as Any,
                              element.accessibilityCustomActions?()?.map(\.name) as Any)
                    }
                }
            }
            _ = try await NativeUI.waitForElement(in: host, id: "module-row-nowPlaying")
            XCTAssertFalse(NativeUI.nativeViews(in: host).contains { $0 is NSTableView })
            let row = try XCTUnwrap(NativeUI.find(in: host, id: "module-row-nowPlaying"))
            var actions = row.accessibilityCustomActions?() ?? []
            XCTAssertFalse(actions.contains { $0.name == L10n.text("Move Up") })
            let down = try XCTUnwrap(actions.first { $0.name == L10n.text("Move Down") })
            XCTAssertEqual(down.handler?(), true)
            try await NativeUI.waitFor("SwiftUI accessibility move down", in: host) { state.orderedModules[1] == .nowPlaying }
            var nonDefaultOrder = ModuleType.allCases
            nonDefaultOrder.swapAt(0, 1)
            XCTAssertNotEqual(nonDefaultOrder, ModuleType.allCases)
            XCTAssertEqual(state.orderedModules, nonDefaultOrder)
            XCTAssertEqual(AppState(preferenceStore: defaults).orderedModules, nonDefaultOrder)
            let moved = try XCTUnwrap(NativeUI.find(in: host, id: "module-row-nowPlaying"))
            actions = moved.accessibilityCustomActions?() ?? []
            let up = try XCTUnwrap(actions.first { $0.name == L10n.text("Move Up") })
            XCTAssertEqual(up.handler?(), true)
            try await NativeUI.waitFor("SwiftUI accessibility move up", in: host) { state.orderedModules.first == .nowPlaying }
            let enabled = state.isModuleEnabled(.nowPlaying)
            let toggle = try XCTUnwrap(NativeUI.find(in: host, id: "data-annotation-id=module-toggle-nowPlaying"))
            XCTAssertEqual(toggle.accessibilityPerformPress?(), true)
            try await NativeUI.waitFor("SwiftUI switch action", in: host) { state.isModuleEnabled(.nowPlaying) == !enabled }
            let button = try XCTUnwrap(NativeUI.elements(in: host).first {
                $0.accessibilityLabel?() == L10n.format("%@ settings", L10n.text("Now Playing"))
            })
            XCTAssertEqual(button.accessibilityPerformPress?(), true)
            try await NativeUI.waitFor("SwiftUI details action", in: host) { details == .nowPlaying }
            XCTAssertEqual(SettingsPane.modules.title, language == "zh-Hans" ? "模块管理" : "Module management")
        }
    }

    private func row(_ first: ModuleType, isAbove second: ModuleType, in root: Any) -> Bool {
        guard let a = NativeUI.find(in: root, id: "module-row-" + first.rawValue)?.accessibilityFrame?(),
              let b = NativeUI.find(in: root, id: "module-row-" + second.rawValue)?.accessibilityFrame?(),
              a.height > 0, b.height > 0 else { return false }
        return a.midY > b.midY
    }

    private func button(_ title: String, in root: Any) -> AnyObject? {
        NativeUI.elements(in: root).first {
            $0.accessibilityLabel?() == L10n.text(title) || $0.accessibilityTitle?() == L10n.text(title)
        }
    }

    private func pressButton(_ title: String, in root: Any, file: StaticString = #filePath, line: UInt = #line) throws {
        let control = try XCTUnwrap(button(title, in: root), title, file: file, line: line)
        XCTAssertEqual(control.accessibilityPerformPress?(), true, title, file: file, line: line)
    }

    private func makeWindow<Content: View>(host: NSHostingView<Content>) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 740, height: 760),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }
}

@MainActor
private final class SettingsOwnerInput: ObservableObject {
    @Published var state: AppState
    var appearances = 0
    init(state: AppState) { self.state = state }
}

private struct SwitchingSettingsHost<Content: View>: View {
    @ObservedObject var owner: SettingsOwnerInput
    @ViewBuilder let content: (AppState) -> Content
    var body: some View {
        content(owner.state).onAppear { owner.appearances += 1 }
    }
}

private struct ModuleDragWiringHarness: View {
    @ObservedObject var appState: AppState
    let capture: ReorderContextCapture
    @State private var draggedItems: [ModuleType] = []

    var body: some View {
        ReorderContextProbe(capture: capture)
            .modifier(ModuleManagementDragModifier(appState: appState, draggedItems: $draggedItems,
                previewWidth: 540, showDetails: { _ in }))
    }
}
