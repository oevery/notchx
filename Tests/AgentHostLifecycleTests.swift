import XCTest
@testable import NotchX

@MainActor
private final class HostAgentSource: AgentStatusSource {
    var callback: (@MainActor (AgentSourceUpdate) -> Void)?
    var starts = 0, stops = 0
    func start(receive: @escaping @MainActor (AgentSourceUpdate) -> Void) {
        starts += 1; callback = receive; receive(.connection(.connected))
    }
    func stop() { stops += 1 }
}

@MainActor
final class AgentHostLifecycleTests: XCTestCase {
    func testLazyActivationVerifiedNavigationAndOldSubscriptionsCannotReviveSessions() throws {
        let source = HostAgentSource()
        var creations = 0, opens = 0
        var handler = "com.openai.codex"
        var application: URL? = URL(fileURLWithPath: "/Applications/Fixture.app")
        let manager = AgentManager(sourceFactory: { creations += 1; return source },
                                   handlerBundleIdentifier: { _ in handler }, applicationForURL: { _ in application })
        defer { manager.setEnabled(false) }
        XCTAssertEqual(creations, 0)
        XCTAssertTrue(manager.groups.isEmpty)
        manager.setEnabled(true); manager.setEnabled(true)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(source.starts, 1)
        let id = AgentSessionID(providerID: "verified-test", sessionID: "thread-1")
        let event = AgentSessionEvent(id: id, runID: "run", requestID: nil, eventID: "event", sequence: 1,
                                     parentID: nil, classification: .userSession, status: .waitingInput,
                                     title: "Fixture", summary: nil, updatedAt: Date())
        source.callback?(.event(event))
        XCTAssertEqual(manager.groups.count, 1)
        XCTAssertEqual(manager.attentionCount, 1)
        let target = AgentVerifiedNavigationTarget(desktopThreadID: "thread-1")
        source.callback?(.navigation(id, target))
        manager.openSession(id) { _ in opens += 1 }
        XCTAssertEqual(opens, 1)
        application = nil
        XCTAssertFalse(manager.canOpenSession(id))
        manager.openSession(id) { _ in opens += 1 }
        application = URL(fileURLWithPath: "/Applications/Fixture.app")
        handler = "untrusted.application"
        XCTAssertFalse(manager.canOpenSession(id))
        manager.openSession(id) { _ in opens += 1 }
        XCTAssertEqual(opens, 1)
        XCTAssertNil(AgentVerifiedNavigationTarget(desktopThreadID: "../invented?x").url)
        handler = "com.openai.codex"
        let old = try XCTUnwrap(source.callback)
        manager.setEnabled(false)
        XCTAssertEqual(source.stops, 1)
        XCTAssertTrue(manager.groups.isEmpty && manager.navigationTargets.isEmpty)
        old(.event(event))
        manager.openSession(id) { _ in opens += 1 }
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertEqual(opens, 1)
        manager.setEnabled(true)
        old(.connection(.connected)); old(.event(event))
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertEqual(source.starts, 2)
        source.callback?(.event(event))
        source.callback?(.navigation(id, target))
        XCTAssertEqual(manager.groups.count, 1)
        source.callback?(.retainingSessions([]))
        XCTAssertTrue(manager.groups.isEmpty && manager.navigationTargets.isEmpty)
        XCTAssertEqual(manager.attentionCount, 0)
        source.callback?(.event(event))
        XCTAssertEqual(manager.groups.count, 1)
        source.callback?(.connection(.permissionDenied))
        source.callback?(.event(event))
        XCTAssertTrue(manager.groups.isEmpty)
        XCTAssertEqual(manager.attentionCount, 0)
        manager.setEnabled(false)
        XCTAssertEqual(source.stops, 2)
    }

    func testCompactSelectionPriorityMatrix() {
        func resolve(_ active: ActiveModule? = nil, explicit: ActiveModule? = nil, hold: ActiveModule? = nil,
                     attention: Bool = false, media: Bool = false, playing: Bool = false,
                     battery: Bool = true, compact: Bool = true, running: Bool = false) -> ActiveModule? {
            CompactModuleSelection.resolve(active: active, explicitSelection: explicit, presentationHold: hold,
                hasVerifiedAgentAttention: attention, hasMedia: media, mediaIsPlaying: playing,
                batteryEnabled: battery, isCompact: compact, hasVerifiedAgentActivity: running)
        }
        XCTAssertEqual(resolve(media: true), .builtIn(.battery))
        XCTAssertEqual(resolve(media: true, playing: true), .builtIn(.nowPlaying))
        XCTAssertEqual(resolve(attention: true, media: true, playing: true), .builtIn(.agent))
        XCTAssertEqual(resolve(running: true), .builtIn(.agent))
        XCTAssertEqual(resolve(media: true, playing: true, running: true), .builtIn(.nowPlaying))
        XCTAssertEqual(resolve(hold: .builtIn(.shelf), running: true), .builtIn(.shelf))
        XCTAssertEqual(resolve(explicit: .builtIn(.shelf), media: true, playing: true), .builtIn(.nowPlaying))
        XCTAssertEqual(resolve(explicit: .builtIn(.shelf), attention: true, compact: false), .builtIn(.shelf))
        XCTAssertEqual(resolve(explicit: .builtIn(.shelf), hold: .builtIn(.teleprompter), attention: true, media: true, playing: true), .builtIn(.teleprompter))
        XCTAssertEqual(resolve(), .builtIn(.battery))
        XCTAssertNil(resolve(battery: false))
        XCTAssertNil(resolve(media: true, battery: false))
        XCTAssertEqual(resolve(media: true, playing: true, battery: false), .builtIn(.nowPlaying))
        for module in [ModuleType.weather, .notifications, .connectivity, .volumeHUD, .battery, .shelf, .nowPlaying] {
            XCTAssertEqual(resolve(.builtIn(module), media: true), .builtIn(.battery))
            XCTAssertEqual(resolve(.builtIn(module), media: true, playing: true), .builtIn(.nowPlaying))
            XCTAssertEqual(resolve(.builtIn(module), media: true, compact: false), .builtIn(module))
        }
        XCTAssertEqual(resolve(.builtIn(.volumeHUD), media: true, playing: true, compact: false), .builtIn(.volumeHUD))
    }
}
