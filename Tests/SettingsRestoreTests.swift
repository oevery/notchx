import Foundation
import XCTest
@testable import NotchX

final class SettingsRestoreTests: XCTestCase {
    @MainActor
    private func withPreferences(_ test: (UserDefaults, String) -> Void) {
        let domain = "app.notchx.tests.restore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer {
            for key in (defaults.persistentDomain(forName: domain) ?? [:]).keys {
                defaults.removeObject(forKey: key)
            }
        }
        test(defaults, domain)
    }

    private let protectedValues: [String: Any] = [
        "module.shelf.items": Data([0, 1, 2, 255]),
        "module.shelf.retentionDays": 2,
        "module.shelf.defaultToShelf": true,
        "module.notifications.maxRetainedItems": 50.0,
        "notifications.history": Data([10, 20, 30]),
        "teleprompter.script": "A script that must survive restoring preferences.",
        "credentials.testPayload": Data([7, 8, 9]),
        "home.leadingPanel": "shelf",
        "home.centerPanel": "agent",
        "home.trailingPanel": "calendar",
        "general.launchAtLogin": true,
        "appearance.animationSpeed": 0.7,
        "permission.testGranted": true
    ]

    @MainActor
    func testMusicRestoreUpdatesPresentationPreferencesAndPreservesModuleAndPermissions() {
        withPreferences { defaults, domain in
            let state = AppState(preferenceStore: defaults)
            state.compactMusicEnabled = false
            state.musicArtworkGlowEnabled = false
            defaults.set(-1, forKey: SettingsDefaults.NowPlaying.pauseRetention.key)
            defaults.set(true, forKey: SettingsDefaults.NowPlaying.browserDetection.key)
            defaults.set(false, forKey: "module.nowPlaying.enabled")
            defaults.set(true, forKey: "permission.testGranted")
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
            session.requestModuleRestore(.nowPlaying)
            session.confirmModuleRestore()
            XCTAssertTrue(state.compactMusicEnabled)
            XCTAssertTrue(state.musicArtworkGlowEnabled)
            XCTAssertEqual(SettingsDefaults.NowPlaying.pauseRetention.read(from: defaults), 5)
            XCTAssertFalse(SettingsDefaults.NowPlaying.browserDetection.read(from: defaults))
            XCTAssertFalse(defaults.bool(forKey: "module.nowPlaying.enabled"))
            XCTAssertTrue(defaults.bool(forKey: "permission.testGranted"))
            let reopened = AppState(preferenceStore: defaults)
            XCTAssertTrue(reopened.compactMusicEnabled)
            XCTAssertTrue(reopened.musicArtworkGlowEnabled)
        }
    }

    @MainActor
    func testGroupRestoreAndUndoPreserveExactValuesAndUnrelatedPreferences() {
        withPreferences { defaults, domain in
            protectedValues.forEach { defaults.set($0.value, forKey: $0.key) }
            defaults.set(217.3567, forKey: SettingsDefaults.Appearance.compactWidth.key)
            defaults.set(42.125, forKey: SettingsDefaults.Appearance.compactHeight.key)
            defaults.set(0.4, forKey: SettingsDefaults.Appearance.bounceAmount.key)
            let before = defaults.persistentDomain(forName: domain)!
            var callbacks: [SettingsRestoreScope] = []
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain) { callbacks.append($0) }

            session.restoreGroup(.compactSize)
            XCTAssertEqual(defaults.double(forKey: SettingsDefaults.Appearance.compactWidth.key), 200)
            XCTAssertEqual(defaults.double(forKey: SettingsDefaults.Appearance.compactHeight.key), 36)
            XCTAssertEqual(defaults.double(forKey: SettingsDefaults.Appearance.bounceAmount.key), 0.4)
            XCTAssertTrue(session.canUndo(.compactSize))
            XCTAssertFalse(session.canUndo(.animation))
            protectedValues.forEach { key, value in
                XCTAssertEqual(NSDictionary(dictionary: [key: defaults.object(forKey: key)!]), NSDictionary(dictionary: [key: value]))
            }

            session.undo(.compactSize)
            XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!), NSDictionary(dictionary: before))
            XCTAssertFalse(session.canUndo(.compactSize))
            XCTAssertEqual(callbacks, [.compactSize, .compactSize])
        }
    }

    @MainActor
    func testUndoRestoresAbsentKeysEvenWhenRegistrationSuppliesAValue() {
        withPreferences { defaults, domain in
            defaults.register(defaults: [SettingsDefaults.Appearance.bounceAmount.key: 0.45])
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, didRestore: { _ in })
            session.restoreGroup(.animation)
            XCTAssertEqual(defaults.double(forKey: SettingsDefaults.Appearance.bounceAmount.key), 0.25)
            session.undo(.animation)
            XCTAssertNil(defaults.persistentDomain(forName: domain)?[SettingsDefaults.Appearance.bounceAmount.key])
            XCTAssertEqual(defaults.double(forKey: SettingsDefaults.Appearance.bounceAmount.key), 0.45)
            XCTAssertNil(defaults.persistentDomain(forName: domain)?[SettingsDefaults.Appearance.animationLevel.key])
        }
    }

    @MainActor
    func testRepeatedRestoreKeepsOriginalUndoAndGroupsStayIndependent() {
        withPreferences { defaults, domain in
            defaults.set(250.25, forKey: SettingsDefaults.Appearance.compactWidth.key)
            defaults.set(0.4, forKey: SettingsDefaults.Appearance.bounceAmount.key)
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, didRestore: { _ in })
            session.restoreGroup(.animation)
            session.restoreGroup(.compactSize)
            session.restoreGroup(.compactSize)
            session.undo(.compactSize)
            XCTAssertEqual(defaults.double(forKey: SettingsDefaults.Appearance.compactWidth.key), 250.25)
            XCTAssertEqual(defaults.double(forKey: SettingsDefaults.Appearance.bounceAmount.key), 0.25)
            XCTAssertTrue(session.canUndo(.animation))
            session.undo(.animation)
            XCTAssertEqual(defaults.double(forKey: SettingsDefaults.Appearance.bounceAmount.key), 0.4)
        }
    }

    @MainActor
    func testManualEditInvalidatesOnlyItsOwnGroupUndo() {
        withPreferences { defaults, domain in
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, didRestore: { _ in })
            session.restoreGroup(.animation)
            session.restoreGroup(.compactSize)
            defaults.set(250.5, forKey: SettingsDefaults.Appearance.compactWidth.key)
            XCTAssertFalse(session.canUndo(.compactSize))
            session.discardUndoIfChanged(.compactSize)
            defaults.set(200.0, forKey: SettingsDefaults.Appearance.compactWidth.key)
            XCTAssertFalse(session.canUndo(.compactSize))
            session.undo(.compactSize)
            XCTAssertEqual(defaults.double(forKey: SettingsDefaults.Appearance.compactWidth.key), 200)
            XCTAssertTrue(session.canUndo(.animation))
        }
    }

    @MainActor
    func testModuleRequestAndCancellationMakeNoWritesOrRuntimeCalls() {
        withPreferences { defaults, domain in
            defaults.set(false, forKey: "module.teleprompter.enabled")
            defaults.set("wordTracking", forKey: SettingsDefaults.Teleprompter.listeningMode.key)
            let before = defaults.persistentDomain(forName: domain)!
            var callbacks = 0
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain) { _ in callbacks += 1 }
            session.requestModuleRestore(.teleprompter)
            XCTAssertEqual(session.pendingModule, .teleprompter)
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!), NSDictionary(dictionary: before))
            session.cancelModuleRestore()
            session.confirmModuleRestore()
            session.restoreGroup(.module(.teleprompter))
            XCTAssertNil(session.pendingModule)
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!), NSDictionary(dictionary: before))
        }
    }

    @MainActor
    func testEveryConfigurableModuleRestoresOnlyItsAllowlistWhileDisabled() {
        let configurable: [ModuleType] = [.nowPlaying, .shelf, .calendar, .weather, .notifications, .teleprompter]
        for module in configurable {
            withPreferences { defaults, domain in
                protectedValues.forEach { defaults.set($0.value, forKey: $0.key) }
                for other in ModuleType.allCases { defaults.set(false, forKey: "module.\(other.rawValue).enabled") }
                // Seed all other module preferences too, so cross-module writes are caught.
                for candidate in configurable {
                    for entry in SettingsRestoreScope.module(candidate).entries {
                        defaults.set("custom.\(entry.key)", forKey: entry.key)
                    }
                }
                let before = defaults.persistentDomain(forName: domain)!
                var callbacks: [SettingsRestoreScope] = []
                let session = SettingsRestoreSession(defaults: defaults, domainName: domain) { callbacks.append($0) }
                session.requestModuleRestore(module)
                session.confirmModuleRestore()
                session.confirmModuleRestore()
                let after = defaults.persistentDomain(forName: domain)!
                let scope = SettingsRestoreScope.module(module)
                let changedKeys = Set(scope.entries.map(\.key))
                for (key, value) in before where !changedKeys.contains(key) {
                    XCTAssertEqual(NSDictionary(dictionary: [key: after[key]!]), NSDictionary(dictionary: [key: value]), "Unexpected change: \(module).\(key)")
                }
                for entry in scope.entries {
                    if let expected = entry.value {
                        XCTAssertEqual(NSDictionary(dictionary: [entry.key: after[entry.key]!]), NSDictionary(dictionary: [entry.key: expected]))
                    } else {
                        XCTAssertNil(after[entry.key], "Default must be absent: \(entry.key)")
                    }
                }
                XCTAssertEqual(Set(after.keys), Set(before.keys).subtracting(scope.entries.filter { $0.value == nil }.map(\.key)))
                XCTAssertEqual(callbacks, [scope])
                XCTAssertFalse(session.canUndo(scope))
                XCTAssertFalse(defaults.bool(forKey: "module.\(module.rawValue).enabled"))
            }
        }
    }

    @MainActor
    func testModulesWithoutPreferencesCannotStartARestore() {
        withPreferences { defaults, domain in
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, didRestore: { _ in XCTFail("No restore expected") })
            for module in [ModuleType.agent] {
                XCTAssertTrue(SettingsRestoreScope.module(module).entries.isEmpty)
                session.requestModuleRestore(module)
                XCTAssertNil(session.pendingModule)
                session.confirmModuleRestore()
            }
            XCTAssertTrue((defaults.persistentDomain(forName: domain) ?? [:]).isEmpty)
        }
    }

    @MainActor
    func testNotificationRestorePreservesLiveHistoryWithoutApplyingDestructiveFeedFiltering() {
        withPreferences { defaults, domain in
            let manager = NotificationManager.shared
            let previousHistory = manager.recentNotifications
            let previousLatest = manager.latestNotification
            defer {
                manager.recentNotifications = previousHistory
                manager.latestNotification = previousLatest
            }
            // Exceed even the largest supported feed limit, regardless of standard defaults.
            let history = (0..<60).map { index in
                IslandNotification(
                    sourceID: "restore-test.\(index)", appName: "Test app", bundleIdentifier: nil,
                    appIcon: "bell", appIconURL: nil, title: "Title \(index)", body: "Body \(index)",
                    senderName: nil, previewText: "Preview \(index)", avatarURL: nil,
                    timestamp: Date(timeIntervalSince1970: Double(index)), tapAction: nil
                )
            }
            manager.recentNotifications = history
            manager.latestNotification = history.first
            defaults.set(50.0, forKey: "module.notifications.maxRetainedItems")
            defaults.set("", forKey: SettingsDefaults.Notifications.enabledSources.key)
            let state = AppState(preferenceStore: defaults)
            state.notificationPreviewsEnabled = false
            state.enabledNotificationSourceIDs = []
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
            session.requestModuleRestore(.notifications)
            session.confirmModuleRestore()
            XCTAssertEqual(manager.recentNotifications.map(\.sourceID), history.map(\.sourceID))
            XCTAssertEqual(manager.recentNotifications.map(\.body), history.map(\.body))
            XCTAssertEqual(manager.latestNotification?.sourceID, history.first?.sourceID)
            XCTAssertEqual(defaults.double(forKey: "module.notifications.maxRetainedItems"), 50)
            XCTAssertTrue(state.notificationPreviewsEnabled)
            XCTAssertEqual(state.enabledNotificationSourceIDs, Set(NotificationFeedSource.allCases.map(\.rawValue)))
        }
    }

    @MainActor
    func testAnimationRestoreAndUndoSynchronizeLiveCachedAppStorageValues() {
        withPreferences { defaults, domain in
            let state = AppState(preferenceStore: defaults)
            state.animationLevelRaw = AnimationLevel.reduced.rawValue
            state.reduceMotion = true
            state.bounceAmount = 0.4
            state.compactIslandWidth = 217.3567
            let before = defaults.persistentDomain(forName: domain)!
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)

            session.restoreGroup(.animation)
            XCTAssertEqual(state.animationLevelRaw, SettingsDefaults.Appearance.animationLevel.value)
            XCTAssertFalse(state.reduceMotion)
            XCTAssertEqual(state.bounceAmount, 0.25)
            XCTAssertEqual(state.reduceMotion, defaults.bool(forKey: SettingsDefaults.Appearance.reduceMotion.key))
            XCTAssertEqual(state.compactIslandWidth, 217.3567)

            session.undo(.animation)
            XCTAssertEqual(state.animationLevelRaw, AnimationLevel.reduced.rawValue)
            XCTAssertTrue(state.reduceMotion)
            XCTAssertEqual(state.bounceAmount, 0.4)
            XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!), NSDictionary(dictionary: before))
        }
    }

    @MainActor
    func testSizeRestoreAndUndoSynchronizeLiveExactFractionalValues() {
        withPreferences { defaults, domain in
            let state = AppState(preferenceStore: defaults)
            state.compactIslandWidth = 217.3567
            state.compactIslandHeight = 42.125
            let before = defaults.persistentDomain(forName: domain)!
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
            session.restoreGroup(.compactSize)
            XCTAssertEqual(state.compactIslandWidth, 200)
            XCTAssertEqual(state.compactIslandHeight, 36)
            session.undo(.compactSize)
            XCTAssertEqual(state.compactIslandWidth, 217.3567)
            XCTAssertEqual(state.compactIslandHeight, 42.125)
            XCTAssertEqual(NSDictionary(dictionary: defaults.persistentDomain(forName: domain)!), NSDictionary(dictionary: before))
        }
    }

    @MainActor
    func testLiveUndoPreservesAbsentRawKeysAndRegisteredFallbacks() {
        withPreferences { defaults, domain in
            defaults.register(defaults: [SettingsDefaults.Appearance.bounceAmount.key: 0.45])
            let state = AppState(preferenceStore: defaults)
            // Populate the wrapper cache before Restore changes the underlying store.
            XCTAssertEqual(state.bounceAmount, 0.45)
            XCTAssertNil(defaults.persistentDomain(forName: domain)?[SettingsDefaults.Appearance.bounceAmount.key])
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
            session.restoreGroup(.animation)
            XCTAssertEqual(state.bounceAmount, 0.25)
            session.undo(.animation)
            XCTAssertEqual(state.bounceAmount, 0.45)
            XCTAssertFalse(state.reduceMotion)
            XCTAssertTrue((defaults.persistentDomain(forName: domain) ?? [:]).isEmpty)
        }
    }

    @MainActor
    func testWeatherAndShelfRestoreSynchronizeLiveValuesWithoutCrossScopeChanges() {
        withPreferences { defaults, domain in
            let state = AppState(preferenceStore: defaults)
            state.temperatureUnit = .fahrenheit
            state.shelfAutoOpenOnDrop = false
            state.shelfExpandOnDragApproach = false
            XCTAssertFalse(AppState(preferenceStore: defaults).shelfExpandOnDragApproach)
            state.reduceMotion = true
            defaults.set(false, forKey: "module.weather.enabled")
            defaults.set(2, forKey: "module.shelf.retentionDays")
            let session = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
            session.requestModuleRestore(.weather)
            session.confirmModuleRestore()
            XCTAssertEqual(state.temperatureUnit, .celsius)
            XCTAssertEqual(defaults.string(forKey: SettingsDefaults.Weather.temperatureUnit.key), state.temperatureUnit.rawValue)
            XCTAssertFalse(state.shelfAutoOpenOnDrop)
            XCTAssertFalse(state.shelfExpandOnDragApproach)
            XCTAssertTrue(state.reduceMotion)
            XCTAssertFalse(defaults.bool(forKey: "module.weather.enabled"))
            session.requestModuleRestore(.shelf)
            session.confirmModuleRestore()
            XCTAssertTrue(state.shelfAutoOpenOnDrop)
            XCTAssertTrue(state.shelfExpandOnDragApproach)
            XCTAssertTrue(AppState(preferenceStore: defaults).shelfExpandOnDragApproach)
            XCTAssertEqual(defaults.integer(forKey: "module.shelf.retentionDays"), 2)
            XCTAssertTrue(state.reduceMotion)
        }
    }

    @MainActor
    func testInjectedStoreCannotSynchronizeSharedAppStateOrWriteStandardPreferences() {
        let standardDomain = Bundle.main.bundleIdentifier ?? "app.notchx"
        let standardBefore = UserDefaults.standard.persistentDomain(forName: standardDomain) ?? [:]
        let sharedUnitBefore = AppState.shared.temperatureUnit
        withPreferences { defaults, domain in
            defaults.set(17.25, forKey: "module.notifications.maxRetainedItems")
            let state = AppState(preferenceStore: defaults)
            guard state.notificationMaxRetainedItems == 17.25 else {
                XCTFail("Notification retention read outside its injected store")
                return
            }
            state.notificationMaxRetainedItems = 4
            XCTAssertEqual(defaults.double(forKey: "module.notifications.maxRetainedItems"), 4)
            state.temperatureUnit = .fahrenheit
            let isolated = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: state)
            isolated.requestModuleRestore(.weather)
            isolated.confirmModuleRestore()
            XCTAssertEqual(state.temperatureUnit, .celsius)

            // A suite without a live state must stay storage-only.
            let storageOnly = SettingsRestoreSession(defaults: defaults, domainName: domain)
            storageOnly.restoreGroup(.animation)
            storageOnly.undo(.animation)
            // Even an accidentally mismatched injection cannot write the shared store.
            let mismatched = SettingsRestoreSession(defaults: defaults, domainName: domain, appState: AppState.shared)
            mismatched.requestModuleRestore(.weather)
            mismatched.confirmModuleRestore()
        }
        XCTAssertEqual(AppState.shared.temperatureUnit, sharedUnitBefore)
        XCTAssertEqual(NSDictionary(dictionary: UserDefaults.standard.persistentDomain(forName: standardDomain) ?? [:]), NSDictionary(dictionary: standardBefore))
    }

    func testDefaultAllowlistExcludesLifecyclePayloadAndRetentionKeys() {
        let scopes: [SettingsRestoreScope] = [.animation, .compactSize] + ModuleType.allCases.map { .module($0) }
        let keys = scopes.flatMap { $0.entries.map(\.key) }
        XCTAssertEqual(keys.count, Set(keys).count)
        XCTAssertFalse(keys.contains { $0.hasSuffix(".enabled") && $0.hasPrefix("module.") })
        XCTAssertTrue(Set(keys).isDisjoint(with: protectedValues.keys))
        XCTAssertFalse(keys.contains { $0.hasPrefix("home.") || $0.contains("script") || $0.contains("retention") || $0.contains("maxRetained") })
    }
}
