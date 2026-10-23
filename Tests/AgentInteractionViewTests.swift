import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
private final class AgentViewFixtureSource: AgentInteractiveSource {
    var receive: (@MainActor (AgentSourceUpdate) -> Void)?
    var messages: [AgentMessageRequest] = []
    func send(_ request: AgentMessageRequest) async -> AgentMessageDelivery { messages.append(request); return .accepted }
    func start(receive: @escaping @MainActor (AgentSourceUpdate) -> Void) {
        self.receive = receive
        receive(.connection(.connected))
    }
    func stop() { receive = nil }
    func respond(id: String, decision: AgentHookDecision) {}
}

@MainActor
private struct AgentMeasuredViewport: View {
    @ObservedObject var state: AppState
    let manager: AgentManager
    let maximumHeight: CGFloat
    var body: some View {
        AgentFullExpandedView(manager: manager).environmentObject(state).notchXLocalized()
            .padding(.horizontal, 8).padding(.bottom, FullExpandedLayout.moduleBottomPadding)
            .padding(.horizontal, 32).padding(.top, FullExpandedLayout.shoulderTopPadding).padding(.bottom, FullExpandedLayout.bottomPadding)
            .frame(width: 658, height: FullExpandedLayout.agentContentHeight(measuredHeight: state.agentPanelContentHeight,
                inlineToolbar: false, availableHeight: maximumHeight))
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
final class AgentInteractionViewTests: XCTestCase {
    func testFixedMusicAndAgentCanvasesFitInsideSmallCurvesAndSoftBottomCorners() {
        let layout = CompactSideLayout()
        for gap in [179, 200] as [CGFloat] {
            for height in [32, 37] as [CGFloat] {
                let width = gap + 2 * layout.totalWidth
                XCTAssertEqual(width - gap, 100, "Both 44pt slots add their separate 6pt curves exactly once")
                let shape = PillShape(topLeadingRadius: layout.cornerInset, topTrailingRadius: layout.cornerInset,
                    bottomLeadingRadius: 12, bottomTrailingRadius: 12, outwardTopCorners: true)
                let path = shape.path(in: CGRect(x: 0, y: 0, width: width, height: height))
                for center in [layout.cornerInset + layout.contentWidth / 2, width - layout.cornerInset - layout.contentWidth / 2] {
                    let r = layout.canvasSize / 2
                    for x in stride(from: center-r, through: center+r, by: 1) {
                        for y in stride(from: height/2-r, through: height/2+r, by: 1) {
                            XCTAssertTrue(path.contains(CGPoint(x: x, y: y)), "Clipped canvas for side width \(layout.totalWidth)")
                        }
                    }
                }
            }
        }
    }

    func testActivityCategoriesKeepObjectsVerbatimAndLocalizeAllOutcomes() {
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        let samples: [(String, String, AgentToolKind)] = [
            ("functions.apply_patch", "/fixture/App/AgentModels.swift", .edit),
            ("mcp__fixture__read_file", "/fixture/AGENTS.md", .read),
            ("functions.exec_command", "rg --files && cat AGENTS.md", .command),
            ("Grep", "compactContentReady", .search), ("functions.update_plan", "Verify viewport", .plan),
            ("custom_unknown_tool", "Literal detail", .other)]
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.setVolatileDomain(original.merging([L10n.preferenceKey: language]) { _, v in v }, forName: UserDefaults.argumentDomain)
            for (name, detail, kind) in samples {
                XCTAssertEqual(AgentToolKind(name: name), kind)
                let expectedObject = kind == .edit || kind == .read ? (detail as NSString).lastPathComponent : detail
                for outcome in [nil, .completed, .failed, .cancelled] as [AgentToolOutcome?] {
                    let activity: AgentCurrentActivity = outcome.map { .completedTool(name: name, detail: detail, outcome: $0) } ?? .tool(name: name, detail: detail)
                    let presentation = AgentActivityPresentation(activity: activity)
                    XCTAssertEqual(presentation.symbol, kind.symbol)
                    XCTAssertTrue(presentation.text.contains(expectedObject))
                    XCTAssertFalse(presentation.text.contains("%@"))
                    let key = kind.template(outcome: outcome)
                    XCTAssertEqual(L10n.bundle.localizedString(forKey: key, value: "MISSING", table: nil), L10n.text(key))
                    if language == "zh-Hans" { XCTAssertNotEqual(L10n.text(key), key) }
                }
            }
            let publicText = "Literal public progress"
            XCTAssertEqual(AgentActivityPresentation(activity: .progress(publicText)).text, publicText)
        }
    }

    func testIdleHeaderHasIntrinsicHitAreaAndStaysBelowActiveRowsAcrossRepeatedToggles() async throws {
        let source = AgentViewFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        let live = CodexAgentState.id(AgentFixtures.thread)
        source.receive?(.event(event(AgentFixtures.thread, status: .running)))
        source.receive?(.event(event(AgentFixtures.other, status: .completed)))
        source.receive?(.interaction(AgentInteractionSnapshot(liveSessionIDs: [live, CodexAgentState.id(AgentFixtures.other)])))
        manager.showSessionList()
        let domain = "app.notchx.tests.idle-header." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        let view = NSHostingView(rootView: AgentMeasuredViewport(state: state, manager: manager, maximumHeight: 420))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 658, height: 600), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        let toggle = try await NativeUI.waitForElement(in: view, id: "agent-toggle-idle")
        let rowID = "agent-select-" + AgentFixtures.other
        let header = try NativeUI.frame(in: view, id: "agent-toggle-idle")
        let liveFrame = try NativeUI.frame(in: view, id: "agent-select-" + live.sessionID)
        XCTAssertLessThan(header.width, 220, "Trailing blank space must not be part of the toggle")
        XCTAssertLessThanOrEqual(header.maxY, liveFrame.minY + 1)
        XCTAssertNil(NativeUI.find(in: view, id: rowID))
        let collapsedHeight = state.agentPanelContentHeight
        window.orderFront(nil)
        try NativeUI.click(at: NSPoint(x: window.frame.maxX - 50, y: header.midY), in: window)
        await NativeUI.drainMainQueue()
        XCTAssertNil(NativeUI.find(in: view, id: rowID), "Blank space beside the island title must not expand idle sessions")
        try NativeUI.click(at: NSPoint(x: header.maxX - 4, y: header.midY), in: window)
        _ = try await NativeUI.waitForElement(in: view, id: rowID)
        let expandedHeader = try NativeUI.frame(in: view, id: "agent-toggle-idle")
        try NativeUI.click(at: NSPoint(x: expandedHeader.minX + 3, y: expandedHeader.midY), in: window)
        try await NativeUI.waitFor("island arrow collapses idle sessions", in: view) { NativeUI.find(in: view, id: rowID) == nil }
        for _ in 0..<3 {
            XCTAssertEqual(toggle.accessibilityPerformPress?(), true)
            _ = try await NativeUI.waitForElement(in: view, id: rowID)
            try await NativeUI.waitFor("idle rows increase natural height", in: view) { state.agentPanelContentHeight > collapsedHeight + 30 }
            XCTAssertEqual(try NativeUI.frame(in: view, id: "agent-toggle-idle").maxY, header.maxY, accuracy: 1)
            XCTAssertEqual(toggle.accessibilityPerformPress?(), true)
            try await NativeUI.waitFor("idle rows collapse without leaving estimated height", in: view) {
                abs(state.agentPanelContentHeight - collapsedHeight) < 1 && NativeUI.find(in: view, id: rowID) == nil
            }
            XCTAssertEqual(try NativeUI.frame(in: view, id: "agent-toggle-idle").maxY, header.maxY, accuracy: 1)
        }
    }

    func testCompactCanvasesRemainInsideIntermediateCollapseGeometry() {
        let gap: CGFloat = 200, side = Constants.compactSideWidth, corner = Constants.compactSideCurve
        let end = CGSize(width: gap + side * 2 + corner * 2, height: 37)
        let start = CGSize(width: 658, height: 480)
        for startTop in [20, 40] as [CGFloat] {
            for index in 0...40 {
                let t = CGFloat(index) / 40
                let width = start.width + (end.width - start.width) * t
                let height = start.height + (end.height - start.height) * t
                let top = startTop + (corner - startTop) * t
                let startBottom = Constants.fullExpandedBottomCornerRadius
                let bottom = startBottom + (Constants.compactNotchBottomCornerRadius - startBottom) * t
                let shape = PillShape(topCornerRadius: top, bottomCornerRadius: bottom)
                var arch = shape; arch.outwardTopCorners = true
                let path = arch.path(in: CGRect(x: 0, y: 0, width: width, height: height))
                for centerX in [(width - gap - side) / 2, (width + gap + side) / 2] {
                    for x in stride(from: centerX - 13, through: centerX + 13, by: 2) {
                        for y in stride(from: (end.height - 26) / 2, through: (end.height + 26) / 2, by: 2) {
                            XCTAssertTrue(path.contains(CGPoint(x: x, y: y)), "Canvas clipped at collapse fraction \(t)")
                        }
                    }
                }
            }
        }
    }

    func testCompactRowAppearsDuringCollapseAndSurvivesReversal() async throws {
        let domain = "app.notchx.tests.agent-collapse." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(true, forKey: "module.agent.enabled")
        let state = AppState(preferenceStore: defaults)
        defer {
            state.cancelAutoDismiss(); state.cancelFullExpandedDismiss(); state.cancelHoverActivation()
            defaults.removePersistentDomain(forName: domain)
        }
        state.holdPresentation(for: .builtIn(.agent))
        state.fullExpandedSelectedTab = .module(.builtIn(.agent))
        state.currentState = .fullExpanded
        let view = NSHostingView(rootView: IslandContainerView().environmentObject(state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 650), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        await NativeUI.drainMainQueue(); view.layoutSubtreeIfNeeded()
        XCTAssertNil(NativeUI.find(in: view, id: "island-compact-row"), "Hidden compact controls must not enter accessibility or keyboard navigation")
        let gate = UUID()
        // Keep a second surface owner pending. Compact content must already
        // be present while the host still owns an unfinished collapse.
        let held = state.beginSurfaceMotion(owner: gate)
        withAnimation(state.notchAnimation) { state.currentState = .compact }
        await NativeUI.drainMainQueue(); view.layoutSubtreeIfNeeded()
        let row = try await NativeUI.waitForElement(in: view, id: "island-compact-row")
        XCTAssertTrue(state.isSurfaceMotionActive)
        state.finishSurfaceMotion(owner: gate, token: held)
        let frame = try XCTUnwrap(row.accessibilityFrame?())
        XCTAssertEqual(frame.maxY, window.frame.maxY, accuracy: 1)
        XCTAssertEqual(frame.midX, window.frame.midX, accuracy: 1)
        // AX container bounds follow the still-animating clipping surface;
        // the actual control must already occupy the compact top band.
        let provider = try await NativeUI.waitForElement(in: view, id: "agent-compact-provider")
        let control = try XCTUnwrap(provider.accessibilityFrame?())
        XCTAssertGreaterThanOrEqual(control.minY, window.frame.maxY - state.size(for: .compact).height - 1)
        XCTAssertLessThanOrEqual(control.maxY, window.frame.maxY + 1)
        XCTAssertLessThanOrEqual(control.height, Constants.compactSlotContentSize + 1)
        XCTAssertEqual(window.contentView?.bounds.height, 650, "The backing canvas deliberately remains expanded")
        withAnimation(state.notchAnimation) { state.currentState = .fullExpanded }
        try await NativeUI.waitFor("compact controls hidden during reversal", in: view) { NativeUI.find(in: view, id: "island-compact-row") == nil }
        withAnimation(state.notchAnimation) { state.currentState = .compact }
        _ = try await NativeUI.waitForElement(in: view, id: "island-compact-row")
    }

    func testMeasuredHeightIncludesHostPaddingAndPinnedFooterSurvivesExpandedPlanScrolling() async throws {
        let source = AgentViewFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        let id = CodexAgentState.id(AgentFixtures.thread)
        source.receive?(.event(event(AgentFixtures.thread, status: .running)))
        for index in 0..<6 {
            source.receive?(.event(AgentSessionEvent(id: CodexAgentState.id("fixture-child-\(index)"), runID: "child-turn",
                requestID: nil, eventID: UUID().uuidString, sequence: 1, parentID: id, classification: .subagent,
                status: .running, title: "Child \(index)", summary: nil, updatedAt: Date())))
        }
        var context = AgentSessionContext(cwd: "/fixture/NotchX", branch: "main", model: "fixture-model",
            prompt: "Check the viewport", promptTurnID: "turn-1", startedAt: Date())
        context.plan = (0..<20).map { AgentPlanStep(step: "Step \($0): " + String(repeating: "check layout ", count: 12), status: "pending") }
        source.receive?(.interaction(AgentInteractionSnapshot(liveSessionIDs: [id], contexts: [id: context])))
        let domain = "app.notchx.tests.agent-pinned." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        let view = NSHostingView(rootView: AgentMeasuredViewport(state: state, manager: manager, maximumHeight: 310))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 658, height: 600), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        let open = try await NativeUI.waitForElement(in: view, id: "agent-open-" + id.sessionID)
        let scroll = try XCTUnwrap(NativeUI.nativeViews(in: view).compactMap { $0 as? NSScrollView }.first)
        try await NativeUI.waitFor("short detail fits measured viewport", in: view) {
            scroll.documentView.map { $0.bounds.height <= scroll.contentView.bounds.height + 1 } == true
        }
        let shortHeight = state.agentPanelContentHeight
        let toggle = try await NativeUI.waitForElement(in: view, id: "agent-toggle-plan-" + id.sessionID)
        XCTAssertEqual(toggle.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("plan grows until screen cap", in: view) {
            state.agentPanelContentHeight > shortHeight + 200 && scroll.documentView.map { $0.bounds.height > scroll.contentView.bounds.height + 100 } == true
        }
        let before = try XCTUnwrap(open.accessibilityFrame?())
        XCTAssertTrue(window.frame.contains(before))
        let time = try NativeUI.frame(in: view, id: "agent-time-" + id.sessionID)
        XCTAssertTrue(window.frame.contains(time))
        scroll.documentView?.scroll(NSPoint(x: 0, y: scroll.documentView!.bounds.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        await NativeUI.drainMainQueue(); view.layoutSubtreeIfNeeded()
        XCTAssertEqual(try NativeUI.frame(in: view, id: "agent-open-" + id.sessionID), before, "Footer stays fixed while the plan scrolls")
        XCTAssertEqual(try NativeUI.frame(in: view, id: "agent-time-" + id.sessionID), time)
        XCTAssertEqual(toggle.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("collapsed plan restores natural height", in: view) { abs(state.agentPanelContentHeight - shortHeight) < 1 }
        let children = try await NativeUI.waitForElement(in: view, id: "agent-toggle-children-" + id.sessionID)
        XCTAssertEqual(children.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("subagents grow the body", in: view) { state.agentPanelContentHeight > shortHeight + 40 }
        XCTAssertTrue(window.frame.contains(try NativeUI.frame(in: view, id: "agent-open-" + id.sessionID)))
        XCTAssertTrue(window.frame.contains(try NativeUI.frame(in: view, id: "agent-time-" + id.sessionID)))
        XCTAssertEqual(children.accessibilityPerformPress?(), true)
        try await NativeUI.waitFor("collapsed children restore natural height", in: view) { abs(state.agentPanelContentHeight - shortHeight) < 1 }
        XCTAssertEqual(FullExpandedLayout.agentContentHeight(measuredHeight: 200, inlineToolbar: false, availableHeight: nil), 222)
        XCTAssertEqual(FullExpandedLayout.agentContentHeight(measuredHeight: 200, inlineToolbar: true, availableHeight: nil), 280)
        XCTAssertEqual(FullExpandedLayout.agentContentHeight(measuredHeight: 900, inlineToolbar: false, availableHeight: 310), 310)
        XCTAssertEqual(FullExpandedLayout.agentContentHeight(measuredHeight: 900, inlineToolbar: true, availableHeight: 1200), 420)
    }

    func testCompactMetricsReserveThePhysicalCameraEvenWithSmallerSavedSettings() {
        let notch = NSRect(x: 400, y: 900, width: 210, height: 37)
        let small = ScreenDetector.compactIslandMetrics(notch: notch, requestedSize: CGSize(width: 168, height: 32))
        XCTAssertGreaterThanOrEqual(small.size.width, notch.width)
        XCTAssertGreaterThanOrEqual(small.size.height, notch.height)
        let large = ScreenDetector.compactIslandMetrics(notch: notch, requestedSize: CGSize(width: 250, height: 45))
        XCTAssertEqual(large.size, CGSize(width: 250, height: 45))
    }

    func testCompletedPanelHasNoReplyReaderAndEmptyOrStaleUserRowsStayHidden() async throws {
        let source = AgentViewFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        let id = CodexAgentState.id(AgentFixtures.thread), marker = "NX-PRIVATE-LONG-REPLY"
        source.receive?(.event(AgentSessionEvent(id: id, runID: "turn-1", requestID: nil, eventID: UUID().uuidString,
            sequence: 1, parentID: nil, classification: .userSession, status: .completed, title: "Fixture session",
            summary: String(repeating: marker + " **text**\n", count: 100), updatedAt: Date())))
        var context = AgentSessionContext(cwd: "/fixture/NotchX", model: "fixture-model", prompt: " \n ", promptTurnID: "turn-1")
        source.receive?(.interaction(AgentInteractionSnapshot(liveSessionIDs: [id], contexts: [id: context])))
        let domain = "app.notchx.tests.agent-brief." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let view = NSHostingView(rootView: AgentFullExpandedView(manager: manager).environmentObject(AppState(preferenceStore: defaults)).notchXLocalized())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 642, height: 304), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        _ = try await NativeUI.waitForElement(in: view, id: "agent-open-" + id.sessionID)
        XCTAssertNil(NativeUI.find(in: view, id: "agent-user-message-" + id.sessionID))
        XCTAssertNil(NativeUI.find(in: view, id: "agent-current-activity-" + id.sessionID))
        for element in NativeUI.elements(in: view) {
            let value: (() -> Any?)? = element.accessibilityValue
            XCTAssertFalse((value?() as? String ?? "").contains(marker))
            XCTAssertFalse((element.accessibilityHelp?() ?? "").contains(marker))
        }
        context.prompt = "A stale prompt"; context.promptTurnID = "old-turn"
        source.receive?(.interaction(AgentInteractionSnapshot(liveSessionIDs: [id], contexts: [id: context])))
        await NativeUI.drainMainQueue()
        view.layoutSubtreeIfNeeded()
        XCTAssertNil(NativeUI.find(in: view, id: "agent-user-message-" + id.sessionID))
    }

    func testSharedCompactSlotsKeepBothAgentControlsOutsideTheCameraGap() async throws {
        let domain = "app.notchx.tests.agent-slots." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        let gap: CGFloat = 200, side = Constants.compactSideWidth
        let corner = Constants.compactSideCurve, height: CGFloat = 37
        let shape = PillShape(topLeadingRadius: corner, topTrailingRadius: corner,
            bottomLeadingRadius: Constants.compactNotchBottomCornerRadius, bottomTrailingRadius: Constants.compactNotchBottomCornerRadius, outwardTopCorners: true)
        let view = NSHostingView(rootView: CompactSideSlots(centerGapWidth: gap,
            leading: AnyView(AgentCompactLeadingView()), trailing: AnyView(AgentCompactCountView()))
            .padding(.horizontal, corner).clipShape(shape).environmentObject(state))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: gap + side * 2 + corner * 2, height: height), styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        let left = try await NativeUI.waitForElement(in: view, id: "agent-compact-provider")
        let right = try await NativeUI.waitForElement(in: view, id: "agent-compact-count")
        let a = try XCTUnwrap(left.accessibilityFrame?()), b = try XCTUnwrap(right.accessibilityFrame?())
        // Both actual buttons fill their equal slot and share its center.
        for frame in [a,b] {
            XCTAssertEqual(frame.width, side, accuracy: 1)
            XCTAssertEqual(frame.height, height, accuracy: 1)
        }
        XCTAssertEqual(a.midY, b.midY, accuracy: 0.5)
        XCTAssertEqual(a.midX, window.frame.minX + corner + side / 2, accuracy: 1)
        XCTAssertEqual(b.midX, window.frame.maxX - corner - side / 2, accuracy: 1)
        XCTAssertLessThanOrEqual(a.maxX, window.frame.minX + corner + side)
        XCTAssertGreaterThanOrEqual(b.minX, window.frame.maxX - corner - side)
        let path = shape.path(in: CGRect(origin: .zero, size: window.frame.size))
        for centerX in [corner + side / 2, window.frame.width - corner - side / 2] {
            let canvas = CGRect(x: centerX - 13, y: height / 2 - 13, width: 26, height: 26)
            for x in stride(from: canvas.minX, through: canvas.maxX, by: 1) {
                for y in stride(from: canvas.minY, through: canvas.maxY, by: 1) {
                    XCTAssertTrue(path.contains(CGPoint(x: x, y: y)), "The full canvas must remain inside the actual curved shell")
                }
            }
        }
    }

    func testManualSessionSelectionSurvivesOtherSessionsNeedingAttention() {
        let source = AgentViewFixtureSource()
        let active = AgentManager(sourceFactory: { source })
        active.setEnabled(true)
        defer { active.setEnabled(false) }
        source.receive?(.event(event(AgentFixtures.thread, status: .running)))
        active.selectSession(CodexAgentState.id(AgentFixtures.thread))
        source.receive?(.event(event(AgentFixtures.other, status: .waitingApproval)))
        XCTAssertEqual(active.attentionCount, 1)
        XCTAssertEqual(active.currentGroup?.id.sessionID, AgentFixtures.thread)
        source.receive?(.retainingSessions([CodexAgentState.id(AgentFixtures.other)]))
        XCTAssertNil(active.selectedSessionID)
        XCTAssertEqual(active.currentGroup?.id.sessionID, AgentFixtures.other)
    }

    func testApprovalControlsRemainAvailableWithoutMessageControls() async throws {
        let source = AgentViewFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true)
        defer { manager.setEnabled(false) }
        let session = CodexAgentState.id(AgentFixtures.thread)
        source.receive?(.event(event(AgentFixtures.thread, status: .waitingApproval)))
        let request = AgentApproval(id: "fixture-request", sessionID: session, turnID: "turn-1",
            tool: "Bash", command: "echo fixture", reason: nil, expiresAt: Date().addingTimeInterval(60))
        let suggestion = AgentSuggestion(id: "fixture-suggestion", target: session, sourceTurnID: "turn-1",
            title: "Fixture suggestion", text: "Check cancellation")
        source.receive?(.interaction(AgentInteractionSnapshot(approvals: [request], suggestions: [suggestion], liveSessionIDs: [session])))
        let domain = "app.notchx.tests.agent-view." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(true, forKey: "module.agent.enabled")
        let state = AppState(preferenceStore: defaults)
        let originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        for language in ["en", "zh-Hans"] {
            manager.showApproval(request.id)
            UserDefaults.standard.setVolatileDomain(originalArguments.merging([L10n.preferenceKey: language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            let view = NSHostingView(rootView: AgentFullExpandedView(manager: manager).environmentObject(state).notchXLocalized())
            let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 380, height: 700),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            defer { window.close() }
            let allow = try await NativeUI.waitForElement(in: view, id: "agent-allow-fixture-request")
            XCTAssertEqual(allow.isAccessibilityEnabled?(), true)
            manager.selectSession(session)
            await NativeUI.drainMainQueue()
            _ = try await NativeUI.waitForElement(in: view, id: "agent-message-input")
            XCTAssertEqual(NativeUI.find(in: view, id: "agent-message-primary")?.isAccessibilityEnabled?(), false)
            let frame = try NativeUI.frame(in: view, id: "agent-open-" + session.sessionID)
            XCTAssertGreaterThanOrEqual(frame.minX, window.frame.minX - 2)
            XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX + 2)
        }
    }

    private func event(_ thread: String, status: AgentActivityStatus) -> AgentSessionEvent {
        AgentSessionEvent(id: CodexAgentState.id(thread), runID: "turn-1", requestID: nil, eventID: UUID().uuidString,
            sequence: 1, parentID: nil, classification: .userSession, status: status, title: "Fixture session",
            summary: nil, updatedAt: Date())
    }

    func testRunningProgressComposerAndOpenActionFitInCompactViewport() async throws {
        let source = AgentViewFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        let session = CodexAgentState.id(AgentFixtures.thread)
        source.receive?(.event(event(AgentFixtures.thread, status: .running)))
        let context = AgentSessionContext(cwd: "/fixture/NotchX", branch: "main", model: "fixture-model",
            prompt: String(repeating: "Long user prompt ", count: 100), promptTurnID: "turn-1", startedAt: Date(), toolDetail: "App/Modules/Agent/AgentPanelViews.swift")
        source.receive?(.interaction(AgentInteractionSnapshot(liveSessionIDs: [session], tools: [session: "Read"], contexts: [session: context], primaryCapabilities: [session: [.queue, .steer]])))
        let domain = "app.notchx.tests.agent-viewport." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        let view = NSHostingView(rootView: AgentFullExpandedView(manager: manager).environmentObject(state).notchXLocalized())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 642, height: 304), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.close() }
        for id in ["agent-user-message-", "agent-current-activity-", "agent-open-"] {
            let element = try await NativeUI.waitForElement(in: view, id: id + session.sessionID)
            let frame = try XCTUnwrap(element.accessibilityFrame?())
            XCTAssertGreaterThanOrEqual(frame.minX, window.frame.minX - 2)
            XCTAssertLessThanOrEqual(frame.maxX, window.frame.maxX + 2)
            XCTAssertGreaterThanOrEqual(frame.minY, window.frame.minY - 2)
            XCTAssertLessThanOrEqual(frame.maxY, window.frame.maxY + 2)
        }
        let inputFrame = try NativeUI.frame(in: view, id: "agent-message-input")
        XCTAssertGreaterThanOrEqual(inputFrame.minY, window.frame.minY - 2)
        XCTAssertLessThanOrEqual(inputFrame.maxX, window.frame.maxX + 2)
        let detailHeight = state.agentPanelContentHeight
        manager.showSessionList()
        try await NativeUI.waitFor("session list uses its content height", in: view) {
            state.agentPanelContentHeight < detailHeight
        }
    }

    func testRunningEndedAndWaitingViewsShowComposerModesAndKeepNativeQuestionsAsReminders() async throws {
        let source = AgentViewFixtureSource(), manager = AgentManager(sourceFactory: { source })
        manager.setEnabled(true); defer { manager.setEnabled(false) }
        let session = CodexAgentState.id(AgentFixtures.thread)
        let domain = "app.notchx.tests.agent-reminder." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let state = AppState(preferenceStore: defaults)
        let view = NSHostingView(rootView: AgentFullExpandedView(manager: manager).environmentObject(state).notchXLocalized())
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 642, height: 330), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        defer { window.contentView = nil; window.close() }
        let original = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain) }
        var sequence: Int64 = 0
        for language in ["en", "zh-Hans"] {
            UserDefaults.standard.setVolatileDomain(original.merging([L10n.preferenceKey: language]) { _, v in v }, forName: UserDefaults.argumentDomain)
            for status in [AgentActivityStatus.running, .completed, .waitingInput] {
                sequence += 1
                let turn = "turn-" + String(sequence)
                source.receive?(.event(AgentSessionEvent(id: session, runID: turn, requestID: nil,
                    eventID: UUID().uuidString, sequence: sequence, parentID: nil, classification: .userSession,
                    status: status, title: "Reminder fixture", summary: nil, updatedAt: Date())))
                let question = AgentInputQuestion(id: "choice", header: "Choice", text: "Which viewport?", isSecret: false, options: [])
                let input = AgentPendingInput(id: "question-" + turn, text: question.text, asynchronous: false, questions: [question], canRespond: true)
                let context = AgentSessionContext(cwd: "/fixture", model: "fixture-model", prompt: "Check viewport", promptTurnID: turn,
                    pendingInput: status == .waitingInput ? input : nil)
                source.receive?(.interaction(AgentInteractionSnapshot(liveSessionIDs: [session], contexts: [session: context],
                    primaryCapabilities: [session: status == .running ? [.steer, .queue] : status.isTerminal ? [.send] : []])))
                manager.setMessageDraft("message fixture", for: session)
                manager.selectSession(session)
                _ = try await NativeUI.waitForElement(in: view, id: "agent-open-" + session.sessionID)
                await NativeUI.drainMainQueue()
                _ = try await NativeUI.waitForElement(in: view, id: "agent-message-input")
                let primary = try await NativeUI.waitForElement(in: view, id: "agent-message-primary")
                XCTAssertEqual(primary.accessibilityLabel?(), L10n.text(status.isTerminal ? "Send" : "Steer"))
                XCTAssertEqual(primary.isAccessibilityEnabled?(), status != .waitingInput)
                XCTAssertEqual(NativeUI.find(in: view, id: "agent-message-queue") != nil, !status.isTerminal)
                XCTAssertNil(NativeUI.find(in: view, id: "agent-answer-" + session.sessionID))
                XCTAssertFalse(manager.panel.isEditing)
                if status == .running {
                    let queue = try await NativeUI.waitForElement(in: view, id: "agent-message-queue")
                    let queueFrame = try XCTUnwrap(queue.accessibilityFrame?())
                    let primaryFrame = try XCTUnwrap(primary.accessibilityFrame?())
                    XCTAssertEqual(queueFrame.midY, primaryFrame.midY, accuracy: 1, "Secondary and primary actions must be centered together")
                    XCTAssertEqual(try NativeUI.frame(in: view, id: "agent-message-input").midY, primaryFrame.midY, accuracy: 2)
                    XCTAssertEqual(queue.accessibilityPerformPress?(), true)
                    try await NativeUI.waitFor("secondary action queues once") { manager.draft(for: session).delivery == .accepted }
                    XCTAssertEqual(source.messages.last?.mode, .queue)
                    manager.setMessageDraft("next native button input", for: session)
                }
                if status != .waitingInput {
                    try await NativeUI.waitFor("updated primary button is enabled", in: view) {
                        NativeUI.find(in: view, id: "agent-message-primary")?.isAccessibilityEnabled?() == true
                    }
                    let currentPrimary = try await NativeUI.waitForElement(in: view, id: "agent-message-primary")
                    XCTAssertEqual(currentPrimary.accessibilityPerformPress?(), true)
                    try await NativeUI.waitFor("primary action confirms") { manager.draft(for: session).delivery == .accepted }
                    XCTAssertEqual(source.messages.last?.mode, status.isTerminal ? .send : .steer)
                    XCTAssertEqual(source.messages.last?.sessionID, session)
                    XCTAssertEqual(source.messages.last?.turnID, turn)
                }
                if status == .waitingInput {
                    _ = try await NativeUI.waitForElement(in: view, id: "agent-pending-input-" + session.sessionID)
                    _ = try await NativeUI.waitForElement(in: view, id: "agent-answer-in-codex-" + session.sessionID)
                } else {
                    XCTAssertNil(NativeUI.find(in: view, id: "agent-pending-input-" + session.sessionID))
                }
            }
        }
    }
}
