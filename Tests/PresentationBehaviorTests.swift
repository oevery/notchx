import XCTest
import Combine
import SwiftUI
import AppKit
@testable import NotchX

@MainActor
final class PresentationBehaviorTests: XCTestCase {
    func testCollapseKeepsWindowMotionAliveUntilEveryCurrentOwnerCompletes() {
        let state = AppState(preferenceStore: UserDefaults(suiteName: "app.notchx.tests.motion." + UUID().uuidString)!)
        state.currentState = .fullExpanded
        let a = UUID(), b = UUID()
        let old = state.beginSurfaceMotion(owner: a), current = state.beginSurfaceMotion(owner: a), other = state.beginSurfaceMotion(owner: b)
        state.currentState = .compact
        XCTAssertTrue(state.isSurfaceMotionActive)
        state.finishSurfaceMotion(owner: a, token: old)
        XCTAssertTrue(state.isSurfaceMotionActive)
        state.finishSurfaceMotion(owner: a, token: current)
        XCTAssertTrue(state.isSurfaceMotionActive)
        state.finishSurfaceMotion(owner: b, token: other)
        XCTAssertFalse(state.isSurfaceMotionActive)
    }

    private func withState(_ body: (AppState, UserDefaults, String) throws -> Void) rethrows {
        let domain = "app.notchx.tests.presentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        defer {
            state.cancelAutoDismiss()
            state.cancelFullExpandedDismiss()
            defaults.removePersistentDomain(forName: domain)
        }
        try body(state, defaults, domain)
    }

    private func withPlayingMedia(_ body: (NowPlayingManager) -> Void) {
        let media = NowPlayingManager.shared
        let previous = (media.title, media.sourceName, media.isPlaying, media.providerStatus,
                        media.duration, media.elapsedTime)
        defer {
            (media.title, media.sourceName, media.isPlaying, media.providerStatus,
             media.duration, media.elapsedTime) = previous
        }
        media.title = "Current track"
        media.sourceName = "Test player"
        media.isPlaying = true
        media.providerStatus = .playing("Test player")
        media.duration = 300
        media.elapsedTime = 60
        body(media)
    }

    func testCompactMusicPreferenceDoesNotDisableManualPlaybackOrStealOpenPages() {
        withPlayingMedia { _ in
            withState { state, defaults, _ in
                state.compactMusicEnabled = false
                XCTAssertFalse(defaults.bool(forKey: SettingsDefaults.NowPlaying.compactMusic.key))
                state.setActiveModule(.nowPlaying)
                XCTAssertEqual(state.compactPresentationModule, .builtIn(.battery))
                state.presentNowPlaying()
                XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.nowPlaying)))
                state.selectFullExpandedTab(.module(.builtIn(.shelf)))
                state.setActiveModule(.nowPlaying)
                XCTAssertEqual(state.activeModule, .builtIn(.shelf))
                XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.shelf)))
                state.dismiss()
                state.compactMusicEnabled = true
                XCTAssertEqual(state.compactPresentationModule, .builtIn(.nowPlaying))
                state.currentState = .expanded
                state.setActiveModule(.calendar, userInitiated: true)
                state.setActiveModule(.nowPlaying)
                XCTAssertEqual(state.activeModule, .builtIn(.calendar))
            }
        }
    }

    func testClosingShelfReturnsToCurrentMusicAndNextOpenStartsAtHome() {
        withPlayingMedia { media in
            withState { state, _, _ in
                state.currentState = .fullExpanded
                state.selectFullExpandedTab(.module(.builtIn(.shelf)))
                state.dismiss()
                XCTAssertNil(state.activeModule)
                XCTAssertEqual(state.compactPresentationModule, .builtIn(.nowPlaying))
                state.open()
                XCTAssertEqual(state.fullExpandedSelectedTab, .home)
                state.dismiss()
                media.isPlaying = false
                // An unavailable player yields immediately, regardless of the
                // user's separate pause-retention preference.
                media.providerStatus = .unavailable("Test player")
                XCTAssertEqual(state.compactPresentationModule, .builtIn(.battery))
                state.batteryEnabled = false
                XCTAssertNil(state.compactPresentationModule)
            }
        }
    }

    func testStaleMediaYieldsButTimelineEndDoesNotOverrideSourcePlaybackState() {
        withPlayingMedia { media in
            withState { state, _, _ in
                state.activeModule = .builtIn(.nowPlaying)
                for status in [NowPlayingProviderStatus.stale("Test player"), .unavailable("Test player"), .paused("Test player")] {
                    media.providerStatus = status
                    XCTAssertEqual(state.compactPresentationModule, .builtIn(.battery))
                }
                media.providerStatus = .paused("Test player")
                XCTAssertNil(media.playbackStatusDescription)
                media.providerStatus = .stale("Test player")
                XCTAssertFalse(media.canControlPlayback)
                XCTAssertNotNil(media.playbackStatusDescription)
                media.providerStatus = .playing("Test player")
                media.elapsedTime = media.duration
                XCTAssertEqual(state.compactPresentationModule, .builtIn(.nowPlaying))
                media.elapsedTime = 0
                XCTAssertEqual(state.compactPresentationModule, .builtIn(.nowPlaying))
            }
        }
    }

    func testClosingPreservesHeldActivityAndDoesNotInterruptLockedOrDraggingContent() {
        withPlayingMedia { _ in
            withState { state, _, _ in
                state.teleprompterEnabled = true
                state.holdPresentation(for: .builtIn(.teleprompter))
                state.setActiveModule(.teleprompter, userInitiated: true)
                state.dismiss()
                XCTAssertEqual(state.compactPresentationModule, .builtIn(.teleprompter))
                state.open()
                XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.teleprompter)))
                state.releasePresentationHold(for: .builtIn(.teleprompter))
                state.selectFullExpandedTab(.module(.builtIn(.shelf)))
                state.lockFullExpandedInPlace = true
                state.dismiss()
                XCTAssertEqual(state.currentState, .fullExpanded)
                XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.shelf)))
                state.lockFullExpandedInPlace = false
                let interaction = state.beginControlInteraction()
                state.dismiss()
                XCTAssertEqual(state.currentState, .fullExpanded)
                state.endControlInteraction(interaction)
                state.dismiss()
                XCTAssertEqual(state.compactPresentationModule, .builtIn(.nowPlaying))
            }
        }
    }

    func testCompactCyclingOpensTemporaryBrowseInsteadOfPinningModule() {
        withState { state, _, _ in
            state.cycleModule(forward: true)
            XCTAssertEqual(state.currentState, .expanded)
            XCTAssertNotNil(state.activeModule)
            state.dismiss()
            XCTAssertEqual(state.compactPresentationModule, .builtIn(.battery))
        }
    }

    func testReleasingHeldActivityInvalidatesTheCompactViewImmediately() {
        withPlayingMedia { _ in
            withState { state, _, _ in
                state.holdPresentation(for: .builtIn(.teleprompter))
                var changes = 0
                let observation = state.objectWillChange.sink { changes += 1 }
                defer { observation.cancel() }
                state.releasePresentationHold(for: .builtIn(.teleprompter))
                XCTAssertGreaterThan(changes, 0)
                XCTAssertEqual(state.compactPresentationModule, .builtIn(.nowPlaying))
            }
        }
    }

    func testTransientEventsReturnToIdleInsteadOfRememberingBrowsedModule() {
        withState { state, _, _ in
            state.setActiveModule(.calendar, userInitiated: true)
            state.showHUD(module: .volumeHUD)
            state.showHUD(module: .volumeHUD)
            state.showHUD(module: .battery)
            XCTAssertEqual(state.activeModule, .builtIn(.battery))
            state.dismiss()
            XCTAssertEqual(state.currentState, .compact)
            XCTAssertNil(state.activeModule)
            XCTAssertEqual(state.compactPresentationModule, .builtIn(.battery))
        }
    }

    func testLatestTimeoutWinsAndManualSelectionCancelsPendingDismissal() async throws {
        let domain = "app.notchx.tests.timer.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        defer {
            state.cancelAutoDismiss()
            defaults.removePersistentDomain(forName: domain)
        }
        state.setActiveModule(.weather)
        state.showHUD(module: .volumeHUD, autoDismissDelay: 0.03)
        state.showHUD(module: .battery, autoDismissDelay: 0.3)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.currentState, .expanded)
        XCTAssertEqual(state.activeModule, .builtIn(.battery))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertNil(state.activeModule)
        state.showHUD(module: .volumeHUD, autoDismissDelay: 0.03)
        state.setActiveModule(.calendar, userInitiated: true)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.currentState, .expanded)
        XCTAssertEqual(state.activeModule, .builtIn(.calendar))
    }

    func testSliderInteractionDefersTimeoutEvenOutsideWindow() async throws {
        let domain = "app.notchx.tests.drag.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let state = AppState(preferenceStore: defaults)
        defer {
            state.cancelAutoDismiss()
            defaults.removePersistentDomain(forName: domain)
        }
        state.setActiveModule(.weather)
        state.showHUD(module: .volumeHUD, autoDismissDelay: 0.03)
        let interaction = state.beginControlInteraction()
        state.handleHoverChange(false)
        state.showHUD(module: .volumeHUD, autoDismissDelay: 0.03)
        state.showHUD(module: .battery)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.currentState, .expanded)
        XCTAssertEqual(state.activeModule, .builtIn(.volumeHUD))
        state.endControlInteraction(interaction)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(state.currentState, .compact)
        XCTAssertNil(state.activeModule)
    }

    func testTransientWithoutPreviousContentClearsAndSkipsDisabledReturnTarget() {
        withState { state, _, _ in
            state.showHUD(module: .volumeHUD)
            state.dismiss()
            XCTAssertNil(state.activeModule)
            state.setActiveModule(.weather)
            state.showHUD(module: .volumeHUD)
            state.weatherEnabled = false
            state.dismiss()
            XCTAssertNil(state.activeModule)
        }
    }

    func testDisablingTransientRestoresUnderlyingModule() {
        withState { state, _, _ in
            state.setActiveModule(.calendar)
            state.showHUD(module: .volumeHUD)
            state.volumeHUDEnabled = false
            state.reconcileEnabledModules()
            XCTAssertEqual(state.activeModule, .builtIn(.calendar))
        }
    }

    func testMediaUpdatesDoNotReplaceHUDAndUserSelectionSupersedesReturnTarget() {
        withState { state, _, _ in
            state.setActiveModule(.weather)
            state.showHUD(module: .volumeHUD)
            state.setActiveModule(.nowPlaying)
            XCTAssertEqual(state.activeModule, .builtIn(.volumeHUD))
            state.dismiss()
            XCTAssertNil(state.activeModule)
            state.showHUD(module: .volumeHUD)
            state.setActiveModule(.calendar, userInitiated: true)
            state.dismiss()
            XCTAssertNil(state.activeModule)
        }
    }

    func testEventsCannotInterruptHeldActivityOrOpenWorkspace() {
        withState { state, _, _ in
            state.setActiveModule(.calendar)
            state.holdPresentation(for: .builtIn(.calendar))
            state.showHUD(module: .volumeHUD)
            XCTAssertEqual(state.activeModule, .builtIn(.calendar))
            state.releasePresentationHold(for: .builtIn(.calendar))
            state.currentState = .fullExpanded
            state.showHUD(module: .battery)
            XCTAssertEqual(state.activeModule, .builtIn(.calendar))
            XCTAssertEqual(state.currentState, .fullExpanded)
        }
    }

    func testHomeMusicVisibilityFollowsConfiguredEnabledPanels() {
        withState { state, _, _ in
            let home = IslandActivityState(islandState: .fullExpanded, activeModule: nil,
                                           fullExpandedTab: .home, isHovering: false, isAppActive: false)
            XCTAssertTrue(state.isModuleVisibleForRefresh(.builtIn(.nowPlaying), state: home))
            state.homeLeadingPanelRaw = HomePanel.none.rawValue
            XCTAssertFalse(state.isModuleVisibleForRefresh(.builtIn(.nowPlaying), state: home))
            state.homeCenterPanelRaw = HomePanel.nowPlaying.rawValue
            XCTAssertTrue(state.isModuleVisibleForRefresh(.builtIn(.nowPlaying), state: home))
            state.nowPlayingEnabled = false
            XCTAssertFalse(state.isModuleVisibleForRefresh(.builtIn(.nowPlaying), state: home))
            let anotherTab = IslandActivityState(islandState: .fullExpanded, activeModule: .builtIn(.nowPlaying),
                                                 fullExpandedTab: .module(.builtIn(.calendar)), isHovering: false, isAppActive: true)
            XCTAssertFalse(state.isModuleVisibleForRefresh(.builtIn(.nowPlaying), state: anotherTab))
        }
    }

    func testPlaybackPageHasANavigationEntryAndSharesPresentationLifecycle() {
        withState { state, _, _ in
            XCTAssertTrue(state.fullExpandedTabs.contains(.module(.builtIn(.nowPlaying))))
            XCTAssertTrue(state.canPresentFullExpandedModule(.builtIn(.nowPlaying)))
            state.presentNowPlaying()
            XCTAssertEqual(state.currentState, .fullExpanded)
            XCTAssertEqual(state.fullExpandedSelectedTab, .module(.builtIn(.nowPlaying)))
            XCTAssertTrue(state.isModuleVisibleForRefresh(.builtIn(.nowPlaying)))
            state.showHomeTab()
            XCTAssertEqual(state.fullExpandedSelectedTab, .home)
            state.nowPlayingEnabled = false
            state.reconcileEnabledModules()
            state.presentNowPlaying()
            XCTAssertEqual(state.fullExpandedSelectedTab, .home)
            XCTAssertFalse(state.fullExpandedTabs.contains(.module(.builtIn(.nowPlaying))))
        }
    }

    func testExplicitNavigationWorksImmediatelyAfterOpeningPlayback() {
        withState { state, _, _ in
            state.presentNowPlaying()
            XCTAssertFalse(state.canHandleIslandSurfaceGesture)
            for target: FullExpandedTab in [.home, .module(.builtIn(.nowPlaying)), .module(.builtIn(.shelf)), .home] {
                state.selectFullExpandedTab(target)
                XCTAssertEqual(state.fullExpandedSelectedTab, target)
                XCTAssertEqual(state.currentState, .fullExpanded)
            }
        }
    }

    func testScrubbingBlocksSurfaceGesturesAndDismissal() {
        withState { state, _, _ in
            state.currentState = .fullExpanded
            let interaction = state.beginControlInteraction()
            XCTAssertFalse(state.canHandleIslandSurfaceGesture)
            state.dismiss()
            XCTAssertEqual(state.currentState, .fullExpanded)
            state.endControlInteraction(interaction)
            state.beginCompactControlInteraction(timeout: 0.25)
            XCTAssertFalse(state.canHandleIslandSurfaceGesture)
        }
    }

    func testModuleOrderPersistsAndRestoreUndoDoesNotChangeSelectionOrEnablement() {
        withState { state, defaults, domain in
            state.agentEnabled = false
            state.setActiveModule(.calendar, userInitiated: true)
            state.moveModule(.weather, to: .nowPlaying)
            let reordered = state.orderedModules
            XCTAssertEqual(reordered.first, .weather)
            XCTAssertEqual(AppState(preferenceStore: defaults).orderedModules, reordered)
            XCTAssertEqual(state.availableModules.first, .builtIn(.weather))
            XCTAssertEqual(state.fullExpandedTabs[1], .module(.builtIn(.weather)))
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
            session.restoreGroup(.moduleOrder)
            XCTAssertEqual(state.orderedModules, ModuleType.allCases)
            session.undo(.moduleOrder)
            XCTAssertEqual(state.orderedModules, reordered)
            XCTAssertFalse(state.agentEnabled)
            XCTAssertEqual(state.compactPresentationModule, .builtIn(.calendar))
            session.restoreGroup(.moduleOrder)
            state.moveModule(.calendar, by: -1)
            session.discardUndoIfChanged(.moduleOrder)
            XCTAssertFalse(session.canUndo(.moduleOrder))
        }
    }

    func testInvalidOrOutdatedModuleOrderKeepsEveryKnownModuleExactlyOnce() {
        let modules = ModuleOrder.resolve("weather,removed,weather,calendar")
        XCTAssertEqual(Array(modules.prefix(2)), [.weather, .calendar])
        XCTAssertEqual(Set(modules), Set(ModuleType.allCases))
        XCTAssertEqual(modules.count, ModuleType.allCases.count)
    }
}

final class PlaybackPositionTests: XCTestCase {
    func testCachedTrackExpiresAndCannotBePresentedAsLiveOrControllable() {
        let capturedAt = Date(timeIntervalSince1970: 1000)
        let snapshot = NowPlayingSnapshot(
            providerID: "mediaRemoteAdapter", title: "Previous track", artist: "Artist", album: "Album",
            duration: 300, elapsedTime: 20, playbackRate: 1, isPlaying: true,
            sourceName: "Test player", bundleIdentifier: "test.player", albumArtist: "",
            artworkURL: nil, trackIdentifier: "track", isLocalFile: false, browserTabURL: "", capturedAt: capturedAt
        )
        XCTAssertTrue(snapshot.canRetainAsHistory(at: capturedAt.addingTimeInterval(599)))
        XCTAssertFalse(snapshot.canRetainAsHistory(at: capturedAt.addingTimeInterval(600)))
        XCTAssertFalse(snapshot.canRetainAsHistory(at: capturedAt.addingTimeInterval(-1)))
        let disconnected = NowPlayingProviderStatus.stale(snapshot.sourceName)
        XCTAssertFalse(disconnected.isLivePlayback)
        XCTAssertFalse(disconnected.canControlPlayback)
        XCTAssertTrue(NowPlayingProviderStatus.paused(snapshot.sourceName).canControlPlayback)
    }
    func testPositionCatchesUpAfterHiddenTimeAndHonorsSlowPlayback() {
        let start = Date(timeIntervalSince1970: 100)
        let position = PlaybackPosition(elapsed: 20, capturedAt: start, duration: 300, rate: 0.5, isPlaying: true)
        XCTAssertEqual(position.elapsed(at: start.addingTimeInterval(120)), 80)
        XCTAssertEqual(position.elapsed(at: start.addingTimeInterval(-10)), 20)
    }

    func testPauseSeekTrackChangeAndEndAreAnchoredToLatestSourcePosition() {
        let start = Date(timeIntervalSince1970: 100)
        let later = start.addingTimeInterval(10)
        let paused = PlaybackPosition(elapsed: 40, capturedAt: start, duration: 300, rate: 1, isPlaying: false)
        XCTAssertEqual(paused.elapsed(at: later), 40)
        let sought = PlaybackPosition(elapsed: 200, capturedAt: later, duration: 300, rate: 2, isPlaying: true)
        XCTAssertEqual(sought.elapsed(at: later.addingTimeInterval(60)), 300)
        let nextTrack = PlaybackPosition(elapsed: 0, capturedAt: later, duration: 100, rate: 1, isPlaying: true)
        XCTAssertEqual(nextTrack.elapsed(at: later.addingTimeInterval(2)), 2)
        let unknownDuration = PlaybackPosition(elapsed: 40, capturedAt: start, duration: 0, rate: 1, isPlaying: true)
        XCTAssertEqual(unknownDuration.elapsed(at: later), 0)
    }
}

final class SettingsPermissionReturnTests: XCTestCase {
    func testAuthorizationReturnSurvivesRestartAndIsConsumedOnce() {
        let domain = "app.notchx.tests.permission.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let now = Date(timeIntervalSince1970: 100)
        SettingsPermissionReturn(defaults: defaults).begin(pane: .module(.calendar), now: now)
        let reopened = SettingsPermissionReturn(defaults: defaults)
        XCTAssertEqual(reopened.take(now: now.addingTimeInterval(30)), .module(.calendar))
        XCTAssertNil(reopened.take(now: now.addingTimeInterval(31)))
    }

    func testExplicitCloseAndExpiredRequestDoNotReopenSettings() {
        let domain = "app.notchx.tests.permission.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let session = SettingsPermissionReturn(defaults: defaults)
        let now = Date(timeIntervalSince1970: 100)
        session.begin(pane: .general, now: now)
        session.cancel()
        XCTAssertNil(session.take(now: now))
        session.begin(pane: .module(.teleprompter), now: now)
        XCTAssertNil(session.take(now: now.addingTimeInterval(601)))
        XCTAssertNil(session.take(now: now))
    }
}

@MainActor
final class MusicLayoutTests: XCTestCase {
    func testMusicFitsNotchedAndInlineContentBudgetsAcrossStatesAndLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/verification/music-layout")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cover = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.orange.setFill()
            rect.fill()
            return true
        }
        for language in ["zh-Hans", "en"] {
            let chinese = language == "zh-Hans"
            let title = chinese ? "梦醒时分（现场演唱会特别版本）很长的歌曲名称" : "A very long live recording title that must remain on one line"
            let subtitles = chinese
                ? ["梁静茹 • 理性与感性作品音乐会 LIVE", "梁静茹 • 理性与感性作品音乐会 LIVE", "播放器 最近播放", "播放器 不可用"]
                : ["Artist • Live concert album", "Artist • Live concert album", "Player last played", "Player unavailable"]
            for (index, subtitle) in subtitles.enumerated() {
                let data = HomeMusicPresentation(title: title, subtitle: subtitle,
                    isPlaying: index == 0, canControlPlayback: index < 2, progress: 60.0 / 230,
                    elapsedText: index == 3 ? "—:—" : "1:00", durationText: "3:50",
                    albumArt: index < 2 ? cover : nil, duration: 230, canSeek: index < 2, isSeeking: index == 1, trackID: "fixture-track",
                    sourceName: chinese ? "网易云音乐" : "NetEase Cloud Music", canOpenPlayer: true,
                    shuffleMode: .tracks, repeatMode: .playlist, canChangeMode: index < 2)
                for width: CGFloat in [228, 594] {
                    let panel = HomeNowPlayingContent(data: data, isDetailed: width > 300)
                        .environment(\.locale, Locale(identifier: language))
                        .environment(\.colorScheme, .dark)
                        .frame(width: width)
                    let host = NSHostingView(rootView: panel)
                    let required = host.fittingSize.height
                    let budgets = [true, false].map { FullExpandedLayout.musicContentHeight(hasShoulderBar: $0) }
                    for budget in budgets {
                        XCTAssertLessThanOrEqual(required, budget, "\(language) status=\(index) width=\(width): music including both time labels exceeds the host budget")
                    }
                    let renderer = ImageRenderer(content: panel.frame(height: budgets.min()!, alignment: .top).clipped().padding(8).background(Color.black))
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.nsImage)
                    let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation)))
                    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try png.write(to: root.appendingPathComponent("\(language)-\(index)-\(Int(width)).png"))
                }
            }
        }
    }
}
