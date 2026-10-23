import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
private final class AgentFocusFixtureSource: AgentInteractiveSource {
    var receive: (@MainActor (AgentSourceUpdate) -> Void)?
    var refreshes = 0
    func respond(id: String, decision: AgentHookDecision) {}
    func refreshConnection() { refreshes += 1 }
    func start(receive: @escaping @MainActor (AgentSourceUpdate) -> Void) {
        self.receive = receive
        receive(.connection(.connected))
        receive(.event(AgentSessionEvent(id: CodexAgentState.id(AgentFixtures.thread), runID: "turn-1",
            requestID: nil, eventID: UUID().uuidString, sequence: 1, parentID: nil, classification: .userSession,
            status: .running, title: "Focus fixture", summary: nil, updatedAt: Date())))
        receive(.interaction(AgentInteractionSnapshot(liveSessionIDs: [CodexAgentState.id(AgentFixtures.thread)],
            isListening: true, receivedEvents: 42, rejectedEvents: 7, eventCounts: ["PreToolUse": 16, "PostToolUse": 17],
            rejectionCounts: ["unknown": 7], primaryCapabilities: [CodexAgentState.id(AgentFixtures.thread): [.steer, .queue]])))
    }
    func stop() { receive = nil }
}

@MainActor
private struct AgentFocusFixture: View {
    @ObservedObject var state: AppState
    let manager: AgentManager
    let outsideAction: () -> Void
    var body: some View {
        VStack {
            AgentFullExpandedView(manager: manager)
                .environment(\.islandContentActive, state.currentState == .fullExpanded)
                .frame(height: 320)
            Button("Elsewhere", action: outsideAction).accessibilityIdentifier("focus-outside-button")
            Spacer()
        }
        .environmentObject(state)
    }
}

private final class AgentFocusFixtureWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private final class AgentFocusHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class AgentFocusAndSettingsTests: XCTestCase {
    func testComposerPreviewDoesNotFocusOrHoldAndCollapsesAfterHoverLeaves() async throws {
        let source = AgentFocusFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true)
        let domain = "app.notchx.tests.agent-focus." + UUID().uuidString
        let preferences = UserDefaults(suiteName: domain)!
        preferences.set(true, forKey: "module.agent.enabled")
        preferences.set(0.03, forKey: "general.expandedAutoDismissDelay")
        let state = AppState(preferenceStore: preferences)
        state.isHovering = true
        state.presentFullExpandedModule(.agent)
        let host = AgentFocusHostingView(rootView: AgentFocusFixture(state: state, manager: manager, outsideAction: {}))
        let window = AgentFocusFixtureWindow(contentRect: CGRect(x: 100, y: 100, width: 658, height: 400),
            styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer {
            window.contentView = nil; window.close(); manager.setEnabled(false)
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            preferences.removePersistentDomain(forName: domain)
        }
        _ = try await NativeUI.waitForElement(in: host, id: "agent-current-activity-" + AgentFixtures.thread)
        window.makeKeyAndOrderFront(nil)
        await NativeUI.drainMainQueue()
        XCTAssertFalse(manager.panel.isEditing, "Becoming key must not begin editing the first text field automatically")
        for _ in 0..<3 {
            state.handleHoverChange(true)
            state.presentFullExpandedModule(.agent)
            await NativeUI.drainMainQueue()
            _ = try await NativeUI.waitForElement(in: host, id: "agent-message-input")
            XCTAssertFalse(manager.panel.isEditing)
            XCTAssertFalse(state.isControlInteractionActive)
            state.handleHoverChange(false)
            try await NativeUI.waitFor("ordinary preview collapses", in: host) { state.currentState == .compact }
        }
        state.handleHoverChange(true)
        state.presentFullExpandedModule(.agent)
        let hold = state.beginControlInteraction(for: .agent)
        state.handleHoverChange(false)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(state.currentState, .fullExpanded, "Preview must preserve other host interaction holds")
        state.endControlInteraction(hold)
        try await NativeUI.waitFor("host hold release restores collapse", in: host) { state.currentState == .compact }
    }

    func testExplicitEditorFocusBlursOnOutsideClickAndReleasesOnlyItsOwnHold() async throws {
        let source = AgentFocusFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true)
        let domain = "app.notchx.tests.editor-focus." + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: domain))
        preferences.set(true, forKey: "module.agent.enabled")
        preferences.set(0.03, forKey: "general.expandedAutoDismissDelay")
        let state = AppState(preferenceStore: preferences)
        state.isHovering = true; state.presentFullExpandedModule(.agent)
        var outsideClicks = 0
        let host = AgentFocusHostingView(rootView: AgentFocusFixture(state: state, manager: manager, outsideAction: { outsideClicks += 1 }))
        let window = AgentFocusFixtureWindow(contentRect: CGRect(x: 100, y: 100, width: 658, height: 400),
            styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer {
            window.contentView = nil; window.close(); manager.setEnabled(false)
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            preferences.removePersistentDomain(forName: domain)
        }
        _ = try await NativeUI.waitForElement(in: host, id: "agent-message-input")
        let editor = try XCTUnwrap(NativeUI.nativeViews(in: host).compactMap { $0 as? NSTextField }.first(where: { $0.isEditable }))
        XCTAssertFalse(manager.panel.isEditing)
        XCTAssertTrue(window.makeFirstResponder(editor))
        try await NativeUI.waitFor("explicit editor focus holds preview") { manager.panel.isEditing && state.isControlInteractionActive }
        let fieldEditor = try XCTUnwrap(window.firstResponder as? NSTextView)
        fieldEditor.insertText("keep focus draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await NativeUI.waitFor("native edit updates original draft") { manager.draft(for: CodexAgentState.id(AgentFixtures.thread)).text == "keep focus draft" }
        let hold = state.beginControlInteraction(for: .agent)
        let frame = try NativeUI.frame(in: host, id: "focus-outside-button")
        let location = window.convertPoint(fromScreen: NSPoint(x: frame.midX, y: frame.midY))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
        try await NativeUI.waitFor("outside button blurs without swallowing its action") { !manager.panel.isEditing && outsideClicks == 1 }
        XCTAssertTrue(state.isControlInteractionActive, "Another host hold remains")
        state.handleHoverChange(false)
        state.endControlInteraction(hold)
        try await NativeUI.waitFor("outside blur restores collapse") { state.currentState == .compact }
        XCTAssertEqual(manager.draft(for: CodexAgentState.id(AgentFixtures.thread)).text, "keep focus draft")
    }

    func testSettingsSummarizeCapabilitiesAndKeepDiagnosticsCollapsedInBothLanguages() async throws {
        let source = AgentFocusFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: root.appendingPathComponent("events.sock").path)
        try configuration.install(bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        let originalHooks = try Data(contentsOf: root.appendingPathComponent("hooks.json"))
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.setVolatileDomain(originalArguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            for width in [380, 700] as [CGFloat] {
                let integration = AgentIntegrationController(configuration: configuration, bundledHelper: URL(fileURLWithPath: "/bin/echo"))
                let host = NSHostingView(rootView: ScrollView {
                    AgentSettingsDetail(manager: manager, integration: integration).frame(maxWidth: .infinity)
                }.frame(width: width).notchXLocalized())
                let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: width, height: 900), styleMask: [], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.contentView = host
                window.orderFront(nil)
                defer { window.contentView = nil; window.close() }
                try await NativeUI.waitFor("connection summary refreshed", in: host) { integration.hasRefreshed }
                for id in ["agent-setting-connection", "agent-setting-activity", "agent-check-connection", "agent-manage-hooks", "agent-codex-enabled"] {
                    let frame = try NativeUI.frame(in: host, id: id)
                    XCTAssertGreaterThanOrEqual(frame.minX, window.frame.minX - 1)
                    XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX + 1)
                }
                XCTAssertNil(NativeUI.find(in: host, id: "agent-setting-delivery"))
                XCTAssertNil(NativeUI.find(in: host, id: "agent-delivery-details"))
                XCTAssertNil(NativeUI.find(in: host, id: "agent-configure-connection"))
                XCTAssertFalse(hasEventCount(in: host))
                // Widths exercise geometry; exercise the same management/lifecycle
                // sequence once per language at the more constrained width.
                guard width == 380 else { continue }
                let refreshes = source.refreshes
                let check = try await NativeUI.waitForElement(in: host, id: "agent-check-connection")
                XCTAssertEqual(check.accessibilityPerformPress?(), true)
                try await NativeUI.waitFor("refresh uses the status source") { source.refreshes == refreshes + 1 }
                XCTAssertNil(NativeUI.find(in: host, id: "agent-configure-connection"))
                XCTAssertFalse(hasEventCount(in: host))
                let manage = try await NativeUI.waitForElement(in: host, id: "agent-manage-hooks")
                XCTAssertEqual(manage.accessibilityPerformPress?(), true)
                let sheet = try await NativeUI.window(containing: "agent-hook-configuration-status")
                let sheetContent = try XCTUnwrap(sheet.contentView)
                _ = try await NativeUI.waitForElement(in: sheetContent, id: "agent-hook-helper-status")
                _ = try await NativeUI.waitForElement(in: sheetContent, id: "agent-reconfigure-hooks")
                _ = try await NativeUI.waitForElement(in: sheetContent, id: "agent-remove-hooks")
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hooks.json")), originalHooks, "Opening management must not change hooks")
                let done = try await NativeUI.waitForElement(in: sheetContent, id: "agent-settings-sheet-done")
                XCTAssertEqual(done.accessibilityPerformPress?(), true)
                try await NativeUI.waitFor("hook management closes") { window.attachedSheet == nil }
                manager.setCodexEnabled(false)
                try await NativeUI.waitFor("off state hides runtime settings", in: host) { runtimeSettingsAreHidden(in: host) }
                manager.setCodexEnabled(true)
                _ = try await NativeUI.waitForElement(in: host, id: "agent-setting-activity")
                let scroll = try XCTUnwrap(NativeUI.nativeViews(in: host).compactMap { $0 as? NSScrollView }.first)
                let collapsedHeight = try XCTUnwrap(scroll.documentView).bounds.height
                let toggle = try await NativeUI.waitForElement(in: host, id: "agent-connection-diagnostics")
                XCTAssertEqual(toggle.accessibilityPerformPress?(), true)
                try await NativeUI.waitFor("diagnostics animate to expanded height", in: host) {
                    scroll.documentView.map { $0.bounds.height > collapsedHeight } == true
                }
                try await NativeUI.waitFor("expanded event diagnostics", in: host) { hasEventCount(in: host) }
                XCTAssertNil(providerToggle(in: host), "Provider cards must not collapse")
                let provider = try await NativeUI.waitForElement(in: host, id: "agent-codex-enabled")
                XCTAssertEqual(provider.accessibilityPerformPress?(), true)
                try await NativeUI.waitFor("provider stops and keeps its settings", in: host) { !manager.codexEnabled && manager.groups.isEmpty }
                _ = try await NativeUI.waitForElement(in: host, id: "agent-manage-hooks")
                try await NativeUI.waitFor("runtime sections leave the accessibility tree", in: host) { runtimeSettingsAreHidden(in: host) }
                XCTAssertLessThan(try XCTUnwrap(scroll.documentView).bounds.height, collapsedHeight)
                manager.setEnabled(false)
                try await NativeUI.waitFor("module off disables the provider switch", in: host) { NativeUI.find(in: host, id: "agent-codex-enabled")?.isAccessibilityEnabled?() == false }
                XCTAssertTrue(runtimeSettingsAreHidden(in: host))
                let offManage = try await NativeUI.waitForElement(in: host, id: "agent-manage-hooks")
                XCTAssertEqual(offManage.accessibilityPerformPress?(), true)
                let offSheet = try await NativeUI.window(containing: "agent-hook-configuration-status")
                let offDone = try await NativeUI.waitForElement(in: XCTUnwrap(offSheet.contentView), id: "agent-settings-sheet-done")
                XCTAssertEqual(offDone.accessibilityPerformPress?(), true)
                try await NativeUI.waitFor("management closes while module off") { window.attachedSheet == nil }
                manager.setEnabled(true)
                XCTAssertFalse(manager.codexEnabled, "The module switch must preserve individual choices")
                let enable = try await NativeUI.waitForElement(in: host, id: "agent-codex-enabled")
                XCTAssertEqual(enable.accessibilityPerformPress?(), true)
                try await NativeUI.waitFor("provider restarts", in: host) { manager.isCodexActive && !manager.groups.isEmpty }
                for id in ["agent-setting-activity", "agent-check-connection", "agent-connection-diagnostics"] {
                    _ = try await NativeUI.waitForElement(in: host, id: id)
                }
                XCTAssertFalse(hasEventCount(in: host), "Diagnostics must return collapsed, without stale expanded content")
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("hooks.json")), originalHooks)
            }
        }
    }

    func testHookManagementActionsUseExistingConfigurationAndPreserveForeignHooks() async throws {
        let source = AgentFocusFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true)
        defer { manager.setEnabled(false) }
        let root = try AgentFixtures.directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let hooks = root.appendingPathComponent("hooks.json")
        let foreign = Data(#"{"extra":"preserved","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo foreign-hook"}]}]}}"#.utf8)
        try foreign.write(to: hooks)
        let configuration = CodexHookConfiguration(root: root, helper: root.appendingPathComponent("managed/helper"), socketPath: root.appendingPathComponent("events.sock").path)
        let integration = AgentIntegrationController(configuration: configuration, bundledHelper: URL(fileURLWithPath: "/bin/echo"))
        let host = NSHostingView(rootView: AgentSettingsDetail(manager: manager, integration: integration).notchXLocalized())
        let window = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await NativeUI.waitFor("initial configuration check", in: host) { integration.hasRefreshed }
        XCTAssertFalse(integration.isInstalled)
        let manage = try await NativeUI.waitForElement(in: host, id: "agent-manage-hooks")
        XCTAssertEqual(manage.accessibilityPerformPress?(), true)
        let sheet = try await NativeUI.window(containing: "agent-hook-configuration-status")
        let content = try XCTUnwrap(sheet.contentView)
        XCTAssertEqual(try Data(contentsOf: hooks), foreign, "Opening the configure sheet must not install anything")
        XCTAssertNil(NativeUI.find(in: content, id: "agent-remove-hooks"), "Unconfigured hooks have no removal action")
        XCTAssertLessThan(content.bounds.height, 540, "Collapsed management should fit its content")
        let previewToggle = try await NativeUI.waitForElement(in: content, id: "agent-hook-preview-toggle")
        XCTAssertEqual(previewToggle.accessibilityPerformPress?(), true)
        _ = try await NativeUI.waitForElement(in: content, id: "agent-hook-configuration-preview")
        XCTAssertEqual(previewToggle.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("preview collapses", in: content) { NativeUI.find(in: content, id: "agent-hook-configuration-preview") == nil }
        let configure = try await NativeUI.waitForElement(in: content, id: "agent-configure-connection")
        XCTAssertEqual(configure.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("explicit temporary hook installation", in: content) { integration.isInstalled && !integration.isWorking }
        let installed = try Data(contentsOf: hooks)
        XCTAssertNil(NativeUI.find(in: content, id: "agent-update-helper"), "Current helpers need no disabled update button")
        XCTAssertTrue(String(decoding: installed, as: UTF8.self).contains("echo foreign-hook"))
        try Data("outdated helper fixture".utf8).write(to: configuration.helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.helper.path)
        await integration.refresh()
        XCTAssertEqual(integration.helperStatus, .outdated)
        let update = try await NativeUI.waitForElement(in: content, id: "agent-update-helper")
        XCTAssertEqual(update.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("temporary helper repaired", in: content) { integration.helperStatus == .current && !integration.isWorking }
        XCTAssertEqual(try Data(contentsOf: hooks), installed, "Updating the helper must preserve configuration")
        let reconfigure = try await NativeUI.waitForElement(in: content, id: "agent-reconfigure-hooks")
        XCTAssertEqual(reconfigure.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("reconfiguration finishes", in: content) { !integration.isWorking }
        XCTAssertEqual(try Data(contentsOf: hooks), installed, "Reconfiguration must be idempotent")
        let remove = try await NativeUI.waitForElement(in: content, id: "agent-remove-hooks")
        XCTAssertEqual(remove.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("temporary hooks removed", in: content) { !integration.isInstalled && !integration.isWorking }
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: hooks)) as? NSDictionary,
            try JSONSerialization.jsonObject(with: foreign) as? NSDictionary)
        let done = try await NativeUI.waitForElement(in: content, id: "agent-settings-sheet-done")
        XCTAssertEqual(done.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("management closes after removal") { window.attachedSheet == nil }
        _ = try await NativeUI.waitForElement(in: host, id: "agent-manage-hooks")
        XCTAssertFalse(integration.isInstalled)
    }

    private func runtimeSettingsAreHidden(in view: NSView) -> Bool {
        ["agent-setting-activity", "agent-check-connection", "agent-connection-diagnostics"]
            .allSatisfy { NativeUI.find(in: view, id: $0) == nil } && !hasEventCount(in: view)
    }

    private func providerToggle(in view: NSView) -> AnyObject? {
        NativeUI.elements(in: view).first {
            $0.accessibilityRole?() == .disclosureTriangle && ($0.accessibilityLabel?() ?? "").contains("Codex")
        }
    }

    private func hasEventCount(in view: NSView) -> Bool {
        NativeUI.elements(in: view).contains { element in
            let value: (() -> Any?)? = element.accessibilityValue
            return (value?() as? String)?.contains(L10n.format("%d hook events received", 42)) == true
        }
    }

}
