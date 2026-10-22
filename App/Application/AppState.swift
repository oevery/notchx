import Combine
import SwiftUI
import AppKit

// MARK: - Island State
enum IslandState: Hashable {
    case compact
    case expanded
    case fullExpanded
}

// MARK: - Module Type
enum ModuleType: String, CaseIterable, Identifiable {
    case nowPlaying
    case volumeHUD
    case battery
    case shelf
    case connectivity
    case calendar
    case weather
    case notifications
    case teleprompter
    case agent
    case tools
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nowPlaying: return "Now Playing"
        case .volumeHUD: return "Volume"
        case .battery: return "Battery"
        case .shelf: return "Shelf"
        case .connectivity: return "Connectivity"
        case .calendar: return "Calendar"
        case .weather: return "Weather"
        case .notifications: return "Notifications"
        case .teleprompter: return "Teleprompter"
        case .agent: return "Agent"
        case .tools: return "Tools"
        }
    }

    var iconName: String {
        switch self {
        case .nowPlaying: return "music.note"
        case .volumeHUD: return "speaker.wave.2.fill"
        case .battery: return "battery.100"
        case .shelf: return "tray.full.fill"
        case .connectivity: return "wifi"
        case .calendar: return "calendar"
        case .weather: return "cloud.sun.fill"
        case .notifications: return "bell.fill"
        case .teleprompter: return "scroll"
        case .agent: return "terminal"
        case .tools: return "wrench.and.screwdriver"
        }
    }
}

enum NotchHapticIntensity: Int, CaseIterable, Identifiable {
    case off = 0
    case subtle = 1
    case medium = 2
    case strong = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .subtle: return "Subtle"
        case .medium: return "Medium"
        case .strong: return "Strong"
        }
    }

    var feedbackSequence: [(delay: TimeInterval, pattern: NSHapticFeedbackManager.FeedbackPattern)] {
        switch self {
        case .off:
            return []
        case .subtle:
            return [(delay: 0, pattern: .generic)]
        case .medium:
            return [(delay: 0, pattern: .alignment)]
        case .strong:
            return [(delay: 0, pattern: .levelChange)]
        }
    }
}

@MainActor
enum HapticFeedbackController {
    private static var pendingWorkItems: [UUID: DispatchWorkItem] = [:]

    static func play(sequence: [(delay: TimeInterval, pattern: NSHapticFeedbackManager.FeedbackPattern)], cancelPending: Bool = true) {
        guard !sequence.isEmpty else { return }

        if cancelPending {
            cancelPendingFeedback()
        }

        for feedback in sequence {
            schedule(pattern: feedback.pattern, after: feedback.delay)
        }
    }

    static func play(named type: String) {
        let soundName: String?
        let sequence: [(delay: TimeInterval, pattern: NSHapticFeedbackManager.FeedbackPattern)]

        switch type {
        case "success":
            soundName = "Glass"
            sequence = [
                (delay: 0, pattern: .alignment),
                (delay: 0.045, pattern: .generic)
            ]
        case "warning":
            soundName = "Funk"
            sequence = [
                (delay: 0, pattern: .levelChange),
                (delay: 0.05, pattern: .alignment)
            ]
        case "error":
            soundName = "Basso"
            sequence = [
                (delay: 0, pattern: .levelChange),
                (delay: 0.06, pattern: .levelChange)
            ]
        case "selection":
            soundName = "Pop"
            sequence = [(delay: 0, pattern: .generic)]
        default:
            soundName = nil
            sequence = [(delay: 0, pattern: .generic)]
        }

        play(sequence: sequence, cancelPending: false)

        if let soundName {
            NSSound(named: soundName)?.play()
        } else {
            NSSound.beep()
        }
    }

    private static func schedule(pattern: NSHapticFeedbackManager.FeedbackPattern, after delay: TimeInterval) {
        let workItemID = UUID()
        var workItem: DispatchWorkItem!
        workItem = DispatchWorkItem {
            pendingWorkItems.removeValue(forKey: workItemID)
            guard !workItem.isCancelled else { return }
            NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
        }

        pendingWorkItems[workItemID] = workItem

        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private static func cancelPendingFeedback() {
        pendingWorkItems.values.forEach { $0.cancel() }
        pendingWorkItems.removeAll()
    }
}

enum FullExpandedTab: Hashable, Identifiable {
    case home
    case module(ActiveModule)

    var id: String {
        switch self {
        case .home:
            return "home"
        case .module(let module):
            switch module {
            case .builtIn(let builtIn):
                return "module.\(builtIn.rawValue)"
            }
        }
    }

    @MainActor
    var iconName: String {
        switch self {
        case .home:
            return "house.fill"
        case .module(let module):
            return module.iconName
        }
    }

    @MainActor
    var iconImage: NSImage? {
        switch self {
        case .home:
            return nil
        case .module(let module):
            return module.iconImage
        }
    }

    @MainActor
    var title: String {
        switch self {
        case .home:
            return "Home"
        case .module(let module):
            return module.displayName
        }
    }
}

// MARK: - App State
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    /// Called from didSet so the window can resize while still inside
    /// the withAnimation block. No GeometryReader exists, so the resize
    /// is invisible to SwiftUI — the surface stays centered on the notch.
    var didChangeState: ((_ from: IslandState, _ to: IslandState) -> Void)?

    @Published var currentState: IslandState = .compact {
        didSet {
            if oldValue != currentState {
                didChangeState?(oldValue, currentState)
            }
            handleStateTransition(from: oldValue, to: currentState)
            refreshEnergyState()
        }
    }
    @Published var activeModule: ActiveModule? = nil {
        didSet { refreshEnergyState() }
    }
    @Published var previousModule: ActiveModule? = nil
    @Published var fullExpandedSelectedTab: FullExpandedTab = .home {
        didSet { refreshEnergyState() }
    }
    @Published var isHovering: Bool = false {
        didSet { refreshEnergyState() }
    }
    @Published private(set) var isAppActive: Bool = true
    @Published private(set) var isShelfDragActive = false
    @Published private(set) var isKeepAwakeActive = false
    @Published private(set) var isKeyboardCleaningActive = false
    private var keyboardCleaningInteraction: IslandInteractionToken?
    private var shelfDragOwners: Set<UUID> = []
    private var controlInteractions: Set<IslandInteractionToken> = []
    var isControlInteractionActive: Bool { !controlInteractions.isEmpty }
    @Published private(set) var presentationHandoffs: [UUID: IslandPresentationHandoff] = [:]
    @Published private(set) var presentationHandoffRevision = UUID()
    private var latestHandoffID: UUID?
    private(set) var presentationRevision = UUID()
    @Published private var handoffSurfaceEvent: UUID?
    // A collapse must not bounce open from a geometry-only resample under the
    // same pointer. Real movement (not necessarily an exit) rearms hovering.
    private var hoverActivationAwaitsMovement = false
    private var pointerInputAvailable = true
    var pointerSamplingRequested: (() -> Void)?
    var pointerMovementResetRequested: (() -> Void)?
    /// Set by IslandWindowController during overshoot animations to prevent
    /// hover-triggered dismiss from firing while the window frame is resizing.
    var suppressDismissScheduling: Bool = false
    @Published private(set) var presentationScreenFrame: NSRect = .zero
    @Published private(set) var presentationVisibleFrame: NSRect = .zero
    @Published private(set) var presentationHasNotch: Bool = false
    @Published private(set) var presentationNotchRect: NSRect? = nil
    // Module enabled states (persisted via UserDefaults)
    @AppStorage("module.nowPlaying.enabled") var nowPlayingEnabled = true
    @AppStorage(SettingsDefaults.NowPlaying.compactMusic.key) var compactMusicEnabled = SettingsDefaults.NowPlaying.compactMusic.value {
        willSet { objectWillChange.send() }
    }
    @AppStorage(SettingsDefaults.NowPlaying.artworkGlow.key) var musicArtworkGlowEnabled = SettingsDefaults.NowPlaying.artworkGlow.value {
        willSet { objectWillChange.send() }
    }
    @AppStorage("module.volumeHUD.enabled") var volumeHUDEnabled = true
    @AppStorage("module.battery.enabled") var batteryEnabled = true
    @AppStorage("module.shelf.enabled") var shelfEnabled = true
    @AppStorage("module.connectivity.enabled") var connectivityEnabled = true
    @AppStorage("module.calendar.enabled") var calendarEnabled = true
    @AppStorage("module.weather.enabled") var weatherEnabled = true
    let weatherPreferences: WeatherPreferences
    // Compatibility projections, not a second preference cache.
    var temperatureUnit: TemperatureUnit {
        get { weatherPreferences.temperatureUnit }
        set { weatherPreferences.temperatureUnit = newValue }
    }
    var windSpeedUnit: WeatherWindUnit {
        get { weatherPreferences.windUnit }
        set { weatherPreferences.windUnit = newValue }
    }
    @AppStorage("module.notifications.enabled") var notificationsEnabled = true
    @AppStorage(SettingsDefaults.Notifications.showPreviews.key) var notificationPreviewsEnabled = SettingsDefaults.Notifications.showPreviews.value
    @AppStorage("module.notifications.maxRetainedItems") var notificationMaxRetainedItems: Double = 10
    @AppStorage(SettingsDefaults.Notifications.enabledSources.key) private var notificationEnabledSourcesRaw = SettingsDefaults.Notifications.enabledSources.value
    @AppStorage("module.teleprompter.enabled") var teleprompterEnabled = false
    @AppStorage("module.agent.enabled") var agentEnabled = false
    @AppStorage("module.tools.enabled") var toolsEnabled = true
    @AppStorage(SettingsDefaults.Tools.awakeDuration.key) private var keepAwakeDurationRaw = SettingsDefaults.Tools.awakeDuration.value
    @AppStorage(SettingsDefaults.Tools.customMinutes.key) private var keepAwakeCustomMinutesRaw = SettingsDefaults.Tools.customMinutes.value
    var keepAwakeCustomMinutes: Double {
        get { KeepAwakeDuration.boundedCustomMinutes(keepAwakeCustomMinutesRaw) }
        set { objectWillChange.send(); keepAwakeCustomMinutesRaw = KeepAwakeDuration.boundedCustomMinutes(newValue) }
    }
    var keepAwakeDuration: KeepAwakeDuration {
        get { KeepAwakeDuration(rawValue: keepAwakeDurationRaw) ?? .thirtyMinutes }
        set { objectWillChange.send(); keepAwakeDurationRaw = newValue.rawValue }
    }
    @AppStorage(SettingsDefaults.Shelf.autoOpenOnDrop.key) var shelfAutoOpenOnDrop = SettingsDefaults.Shelf.autoOpenOnDrop.value
    @AppStorage(SettingsDefaults.Shelf.expandOnDragApproach.key) var shelfExpandOnDragApproach = SettingsDefaults.Shelf.expandOnDragApproach.value
    @AppStorage("module.shelf.defaultToShelf") var shelfDefaultToShelf = false
    @AppStorage(ModuleOrder.key) private var moduleOrderRaw = ""

    // Appearance settings
    @AppStorage("appearance.animationSpeed") var animationSpeed: Double = 1.0
    @AppStorage(SettingsDefaults.Appearance.bounceAmount.key) var bounceAmount = SettingsDefaults.Appearance.bounceAmount.value
    @AppStorage(SettingsDefaults.Appearance.animationLevel.key) var animationLevelRaw = SettingsDefaults.Appearance.animationLevel.value
    @AppStorage(SettingsDefaults.Appearance.reduceMotion.key) var reduceMotion = SettingsDefaults.Appearance.reduceMotion.value
    @AppStorage(SettingsDefaults.Appearance.compactWidth.key) var compactIslandWidth = SettingsDefaults.Appearance.compactWidth.value
    @AppStorage(SettingsDefaults.Appearance.compactHeight.key) var compactIslandHeight = SettingsDefaults.Appearance.compactHeight.value

    @AppStorage("home.leadingPanel") var homeLeadingPanelRaw = HomePanel.nowPlaying.rawValue
    @AppStorage("home.centerPanel") var homeCenterPanelRaw = HomePanel.calendar.rawValue
    @AppStorage("home.trailingPanel") var homeTrailingPanelRaw = HomePanel.weather.rawValue

    // General settings
    @AppStorage("general.showMenuBarIcon") var showMenuBarIcon = true
    @AppStorage("general.showOnAllSpaces") var showOnAllSpaces = true
    @AppStorage("general.showInScreenRecordings") var showInScreenRecordings = false
    @AppStorage("general.expandedAutoDismissDelay") var expandedAutoDismissDelay: Double = 0.5
    @AppStorage("general.hoverExpandDelay") var hoverExpandDelay: Double = 0.2
    @AppStorage("general.notchHapticIntensity") var notchHapticIntensity = NotchHapticIntensity.medium.rawValue
    @AppStorage(QuitHotkeyGuard.defaultsKey) var allowQuitHotkey = true
    @AppStorage("general.lockFullExpandedInPlace") var lockFullExpandedInPlace = false
    @AppStorage("general.hideSideSlots") var hideSideSlots = false
    @AppStorage("general.hideOnFullscreen") var hideOnFullscreen = false
    /// User-chosen display for the island. Empty string == "Automatic"
    /// (original fallback chain: panel.screen → cursor → primary).
    @AppStorage("general.displayIdentifier") var displayIdentifier: String = ""
    /// Trackpad two-finger and drag swipes on the island surface (cycle modules, expand/dismiss).
    @AppStorage("general.islandSurfaceSwipeEnabled") var islandSurfaceSwipeEnabled = true
    @AppStorage("onboarding.completed") var onboardingCompleted = false
    @AppStorage("debug.alwaysShowOnboarding") var debugAlwaysShowOnboarding = false

    // Energy settings
    @AppStorage("energy.mode") private var energyModeRawValue = EnergyMode.smart.rawValue
    @AppStorage(SettingsDefaults.Appearance.reduceAnimations.key) var reduceAnimations = SettingsDefaults.Appearance.reduceAnimations.value
    @AppStorage("energy.lowPowerSuggestionDoNotAskAgain") var lowPowerSuggestionDoNotAskAgain = false

    private var autoDismissWorkItem: DispatchWorkItem?
    private var fullExpandedDismissWorkItem: DispatchWorkItem?
    private var hoverActivationWorkItem: DispatchWorkItem?
    private var systemEmojiInteractionWorkItem: DispatchWorkItem?
    private var systemEmojiInteractionExpiry: Date?
    private var explicitlySelectedModule: ActiveModule?
    private var presentationHoldModule: ActiveModule?
    private var transientHUD: ActiveModule?
    private var moduleBeforeHUD: ActiveModule?
    private var transientHUDDelay: TimeInterval = 2.5
    private var autoDismissGeneration = UUID()
    private var fullExpandedDismissGeneration = UUID()
    private var hoverActivationGeneration = UUID()
    private var lastNotchEntryHapticDate: Date = .distantPast
    private let restoredPreferenceStore: UserDefaults
    var modulePreferenceStore: UserDefaults { restoredPreferenceStore }
    let preferenceDomainName: String
    // Connected only by the live composition root. Isolated states never activate global managers.
    var moduleEnablementDidChange: (() -> Void)?
    var moduleEnablementWillChange: ((ModuleType, Bool) -> Bool)?
    var presentationPreferencesDidChange: (() -> Void)?
    var refreshScheduler: ModuleRefreshScheduler?
    @Published private(set) var modulePresentationRevision = 0

    func modulePresentationDidChange() {
        modulePresentationRevision += 1
        refreshEnergyState()
    }
    @Published var presentationPreferences = IslandPresentationPreferences() {
        didSet {
            presentationPreferences.saveChanges(from: oldValue, to: restoredPreferenceStore)
            pendingIslandEvents.removeAll { !presentationPreferences[$0].enabled }
            if oldValue[.calendarReminder].enabled != presentationPreferences[.calendarReminder].enabled {
                presentationPreferencesDidChange?()
            }
            refreshEnergyState()
        }
    }
    @Published private(set) var pendingIslandEvents: [IslandEventKind] = []

    /// Bind the resettable preferences to an isolated store in tests. The host uses standard defaults.
    init(preferenceStore: UserDefaults = .standard, preferenceDomainName: String = Bundle.main.bundleIdentifier ?? "app.notchx") {
        self.preferenceDomainName = preferenceDomainName
        restoredPreferenceStore = preferenceStore
        weatherPreferences = preferenceStore === UserDefaults.standard ? .shared : WeatherPreferences(defaults: preferenceStore)
        _presentationPreferences = Published(initialValue: IslandPresentationPreferences.load(from: preferenceStore))
        _nowPlayingEnabled = AppStorage(wrappedValue: true, "module.nowPlaying.enabled", store: preferenceStore)
        _compactMusicEnabled = AppStorage(wrappedValue: SettingsDefaults.NowPlaying.compactMusic.value, SettingsDefaults.NowPlaying.compactMusic.key, store: preferenceStore)
        _musicArtworkGlowEnabled = AppStorage(wrappedValue: SettingsDefaults.NowPlaying.artworkGlow.value, SettingsDefaults.NowPlaying.artworkGlow.key, store: preferenceStore)
        _volumeHUDEnabled = AppStorage(wrappedValue: true, "module.volumeHUD.enabled", store: preferenceStore)
        _batteryEnabled = AppStorage(wrappedValue: true, "module.battery.enabled", store: preferenceStore)
        _shelfEnabled = AppStorage(wrappedValue: true, "module.shelf.enabled", store: preferenceStore)
        _shelfDefaultToShelf = AppStorage(wrappedValue: false, "module.shelf.defaultToShelf", store: preferenceStore)
        _connectivityEnabled = AppStorage(wrappedValue: true, "module.connectivity.enabled", store: preferenceStore)
        _calendarEnabled = AppStorage(wrappedValue: true, "module.calendar.enabled", store: preferenceStore)
        _weatherEnabled = AppStorage(wrappedValue: true, "module.weather.enabled", store: preferenceStore)
        _notificationsEnabled = AppStorage(wrappedValue: true, "module.notifications.enabled", store: preferenceStore)
        _teleprompterEnabled = AppStorage(wrappedValue: false, "module.teleprompter.enabled", store: preferenceStore)
        _agentEnabled = AppStorage(wrappedValue: false, "module.agent.enabled", store: preferenceStore)
        _toolsEnabled = AppStorage(wrappedValue: true, "module.tools.enabled", store: preferenceStore)
        _keepAwakeDurationRaw = AppStorage(wrappedValue: SettingsDefaults.Tools.awakeDuration.value, SettingsDefaults.Tools.awakeDuration.key, store: preferenceStore)
        _keepAwakeCustomMinutesRaw = AppStorage(wrappedValue: SettingsDefaults.Tools.customMinutes.value, SettingsDefaults.Tools.customMinutes.key, store: preferenceStore)
        _homeLeadingPanelRaw = AppStorage(wrappedValue: HomePanel.nowPlaying.rawValue, "home.leadingPanel", store: preferenceStore)
        _homeCenterPanelRaw = AppStorage(wrappedValue: HomePanel.calendar.rawValue, "home.centerPanel", store: preferenceStore)
        _homeTrailingPanelRaw = AppStorage(wrappedValue: HomePanel.weather.rawValue, "home.trailingPanel", store: preferenceStore)
        _lockFullExpandedInPlace = AppStorage(wrappedValue: false, "general.lockFullExpandedInPlace", store: preferenceStore)
        _expandedAutoDismissDelay = AppStorage(wrappedValue: 0.5, "general.expandedAutoDismissDelay", store: preferenceStore)
        _showOnAllSpaces = AppStorage(wrappedValue: true, "general.showOnAllSpaces", store: preferenceStore)
        _showMenuBarIcon = AppStorage(wrappedValue: true, "general.showMenuBarIcon", store: preferenceStore)
        _showInScreenRecordings = AppStorage(wrappedValue: false, "general.showInScreenRecordings", store: preferenceStore)
        _energyModeRawValue = AppStorage(wrappedValue: EnergyMode.smart.rawValue, "energy.mode", store: preferenceStore)
        _notchHapticIntensity = AppStorage(wrappedValue: NotchHapticIntensity.medium.rawValue, "general.notchHapticIntensity", store: preferenceStore)
        _allowQuitHotkey = AppStorage(wrappedValue: true, QuitHotkeyGuard.defaultsKey, store: preferenceStore)
        _hideSideSlots = AppStorage(wrappedValue: false, "general.hideSideSlots", store: preferenceStore)
        _hideOnFullscreen = AppStorage(wrappedValue: false, "general.hideOnFullscreen", store: preferenceStore)
        _islandSurfaceSwipeEnabled = AppStorage(wrappedValue: true, "general.islandSurfaceSwipeEnabled", store: preferenceStore)
        _onboardingCompleted = AppStorage(wrappedValue: false, "onboarding.completed", store: preferenceStore)
        _debugAlwaysShowOnboarding = AppStorage(wrappedValue: false, "debug.alwaysShowOnboarding", store: preferenceStore)
        _lowPowerSuggestionDoNotAskAgain = AppStorage(wrappedValue: false, "energy.lowPowerSuggestionDoNotAskAgain", store: preferenceStore)
        _hoverExpandDelay = AppStorage(wrappedValue: 0.2, "general.hoverExpandDelay", store: preferenceStore)
        _moduleOrderRaw = AppStorage(wrappedValue: "", ModuleOrder.key, store: preferenceStore)
        _animationLevelRaw = AppStorage(wrappedValue: SettingsDefaults.Appearance.animationLevel.value, SettingsDefaults.Appearance.animationLevel.key, store: preferenceStore)
        _animationSpeed = AppStorage(wrappedValue: 1.0, "appearance.animationSpeed", store: preferenceStore)
        _displayIdentifier = AppStorage(wrappedValue: "", "general.displayIdentifier", store: preferenceStore)
        _reduceAnimations = AppStorage(wrappedValue: SettingsDefaults.Appearance.reduceAnimations.value, SettingsDefaults.Appearance.reduceAnimations.key, store: preferenceStore)
        _reduceMotion = AppStorage(wrappedValue: SettingsDefaults.Appearance.reduceMotion.value, SettingsDefaults.Appearance.reduceMotion.key, store: preferenceStore)
        _bounceAmount = AppStorage(wrappedValue: SettingsDefaults.Appearance.bounceAmount.value, SettingsDefaults.Appearance.bounceAmount.key, store: preferenceStore)
        _compactIslandWidth = AppStorage(wrappedValue: SettingsDefaults.Appearance.compactWidth.value, SettingsDefaults.Appearance.compactWidth.key, store: preferenceStore)
        _compactIslandHeight = AppStorage(wrappedValue: SettingsDefaults.Appearance.compactHeight.value, SettingsDefaults.Appearance.compactHeight.key, store: preferenceStore)
        _shelfAutoOpenOnDrop = AppStorage(wrappedValue: SettingsDefaults.Shelf.autoOpenOnDrop.value, SettingsDefaults.Shelf.autoOpenOnDrop.key, store: preferenceStore)
        _shelfExpandOnDragApproach = AppStorage(wrappedValue: SettingsDefaults.Shelf.expandOnDragApproach.value, SettingsDefaults.Shelf.expandOnDragApproach.key, store: preferenceStore)
        _notificationPreviewsEnabled = AppStorage(wrappedValue: SettingsDefaults.Notifications.showPreviews.value, SettingsDefaults.Notifications.showPreviews.key, store: preferenceStore)
        _notificationMaxRetainedItems = AppStorage(wrappedValue: 10, "module.notifications.maxRetainedItems", store: preferenceStore)
        _notificationEnabledSourcesRaw = AppStorage(wrappedValue: SettingsDefaults.Notifications.enabledSources.value, SettingsDefaults.Notifications.enabledSources.key, store: preferenceStore)
    }

    /// AppStorage inside an ObservableObject caches its wrapped value. A defaults write
    /// plus objectWillChange does not update that cache, so restore through the typed setters.
    func synchronizeRestoredPreferences(_ scope: SettingsRestoreScope, from defaults: UserDefaults, domainName: String) {
        guard defaults === restoredPreferenceStore else { return }
        let rawValues = defaults.persistentDomain(forName: domainName) ?? [:]
        objectWillChange.send()
        if case .module = scope { presentationPreferences = .load(from: defaults) }
        switch scope {
        case .moduleOrder:
            moduleOrderRaw = defaults.string(forKey: ModuleOrder.key) ?? ""
        case .animation:
            animationLevelRaw = SettingsDefaults.Appearance.animationLevel.read(from: defaults)
            reduceMotion = SettingsDefaults.Appearance.reduceMotion.read(from: defaults)
            reduceAnimations = SettingsDefaults.Appearance.reduceAnimations.read(from: defaults)
            bounceAmount = SettingsDefaults.Appearance.bounceAmount.read(from: defaults)
            refreshEnergyState()
        case .compactSize:
            compactIslandWidth = SettingsDefaults.Appearance.compactWidth.read(from: defaults)
            compactIslandHeight = SettingsDefaults.Appearance.compactHeight.read(from: defaults)
        case .module(.nowPlaying):
            compactMusicEnabled = SettingsDefaults.NowPlaying.compactMusic.read(from: defaults)
            musicArtworkGlowEnabled = SettingsDefaults.NowPlaying.artworkGlow.read(from: defaults)
        case .module(.shelf):
            shelfAutoOpenOnDrop = SettingsDefaults.Shelf.autoOpenOnDrop.read(from: defaults)
            shelfExpandOnDragApproach = SettingsDefaults.Shelf.expandOnDragApproach.read(from: defaults)
        case .module(.tools):
            keepAwakeDuration = KeepAwakeDuration(rawValue: SettingsDefaults.Tools.awakeDuration.read(from: defaults)) ?? .thirtyMinutes
            keepAwakeCustomMinutes = SettingsDefaults.Tools.customMinutes.read(from: defaults)
        case .module(.weather):
            weatherPreferences.reload()
        case .module(.notifications):
            notificationPreviewsEnabled = SettingsDefaults.Notifications.showPreviews.read(from: defaults)
            notificationEnabledSourcesRaw = SettingsDefaults.Notifications.enabledSources.read(from: defaults)
        default:
            return
        }
        // Typed setters also persist. Retain the transaction's exact raw representation,
        // especially missing keys restored by Undo and registration-domain fallbacks.
        for entry in scope.entries {
            if let value = rawValues[entry.key] { defaults.set(value, forKey: entry.key) }
            else { defaults.removeObject(forKey: entry.key) }
        }
    }

    // MARK: - Animations

    var motion: IslandMotion {
        IslandMotion(speed: animationSpeed, reduced: shouldReduceMotion,
                     bounce: min(bounceAmount, animationLevel.bounceLimit))
    }
    var notchAnimation: Animation { motion.surface }
    var contentSwapAnimation: Animation { motion.content }
    var hoverAnimation: Animation { motion.feedback }

    var surfaceMotionBegan: (() -> Void)?
    var surfaceMotionSettled: (() -> Void)?
    private var surfaceCompletions = IslandTransitionCompletions()
    var isSurfaceMotionActive: Bool { surfaceCompletions.isActive }

    func beginSurfaceMotion(owner: UUID) -> UUID {
        let token = surfaceCompletions.begin(owner: owner)
        // Registration runs inside SwiftUI's transaction update. Window resizing
        // must wait until that update returns, or AppKit re-enters AttributeGraph.
        Task { @MainActor [weak self] in
            guard let self, self.isSurfaceMotionActive else { return }
            self.surfaceMotionBegan?()
        }
        return token
    }
    func finishSurfaceMotion(owner: UUID, token: UUID) {
        if surfaceCompletions.finish(owner: owner, token: token) {
            surfaceMotionSettled?()
        }
    }
    func removeSurfaceMotion(owner: UUID) {
        if surfaceCompletions.remove(owner: owner) {
            surfaceMotionSettled?()
        }
    }
    func settleInitialSurface() {
        // An initially mounted surface has no previous geometry to animate.
        // Other windows may still own real transitions.
        if !surfaceCompletions.isActive { surfaceMotionSettled?() }
    }

    var energyMode: EnergyMode {
        get { EnergyMode(rawValue: energyModeRawValue) ?? .smart }
        set {
            guard energyModeRawValue != newValue.rawValue else { return }
            energyModeRawValue = newValue.rawValue
            refreshEnergyState()
        }
    }

    var effectiveEnergyMode: EnergyMode {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? .lowPower : energyMode
    }

    var shouldReduceAnimations: Bool {
        reduceAnimations || effectiveEnergyMode == .lowPower || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    var shouldReduceMotion: Bool {
        reduceMotion || animationLevel == .reduced || shouldReduceAnimations
    }

    var animationLevel: AnimationLevel {
        get { AnimationLevel(rawValue: animationLevelRaw) ?? .full }
        set { animationLevelRaw = newValue.rawValue }
    }

    /// Summarize legacy manual flags without rewriting them while browsing settings.
    /// System accessibility and Low Power overrides stay independent.
    var manualMotionLevel: AnimationLevel {
        get { reduceMotion || reduceAnimations ? .reduced : animationLevel }
        set {
            guard newValue != manualMotionLevel else { return }
            objectWillChange.send()
            animationLevel = newValue
            reduceMotion = newValue == .reduced
            reduceAnimations = newValue == .reduced
            refreshEnergyState()
        }
    }

    var homePanels: [HomePanel] {
        let configured = [
            HomePanel(rawValue: homeLeadingPanelRaw) ?? .nowPlaying,
            HomePanel(rawValue: homeCenterPanelRaw) ?? .calendar,
            HomePanel(rawValue: homeTrailingPanelRaw) ?? .weather
        ]

        var seen = Set<HomePanel>()
        return configured.filter { panel in
            guard panel != .none else { return false }
            guard seen.insert(panel).inserted else { return false }
            guard let module = panel.module else { return false }
            return isModuleEnabled(module)
        }
    }

    var enabledNotificationSourceIDs: Set<String> {
        get {
            Set(notificationEnabledSourcesRaw
                .split(separator: ",")
                .map { String($0) }
                .filter { !$0.isEmpty })
        }
        set {
            notificationEnabledSourcesRaw = NotificationFeedSource.allCases
                .map(\.rawValue)
                .filter { newValue.contains($0) }
                .joined(separator: ",")
        }
    }

    func isNotificationSourceEnabled(_ source: NotificationFeedSource) -> Bool {
        enabledNotificationSourceIDs.contains(source.rawValue)
    }

    func setNotificationSource(_ source: NotificationFeedSource, enabled: Bool) {
        var enabledSources = enabledNotificationSourceIDs
        if enabled {
            enabledSources.insert(source.rawValue)
        } else {
            enabledSources.remove(source.rawValue)
        }
        enabledNotificationSourceIDs = enabledSources
    }

    func setAppActive(_ active: Bool) {
        guard isAppActive != active else { return }
        isAppActive = active
        refreshEnergyState()
        pointerSamplingRequested?()
    }

    func refreshEnergyState() {
        guard let refreshScheduler else { return }
        let activity = IslandActivityState(
            islandState: currentState,
            activeModule: activeModule,
            fullExpandedTab: fullExpandedSelectedTab,
            isHovering: isHovering,
            isAppActive: isAppActive,
            compactModule: compactPresentationModule,
            homeModules: Set(homePanels.compactMap { $0.module.map(ActiveModule.builtIn) })
        )
        refreshScheduler.updateActivityState(activity)
    }

    func isModuleVisibleForRefresh(_ module: ActiveModule) -> Bool {
        isModuleVisibleForRefresh(
            module,
            state: IslandActivityState(
                islandState: currentState,
                activeModule: activeModule,
                fullExpandedTab: fullExpandedSelectedTab,
                isHovering: isHovering,
                isAppActive: isAppActive
            )
        )
    }

    func isModuleVisibleForRefresh(_ module: ActiveModule, state: IslandActivityState) -> Bool {
        var context = state
        context.compactModule = compactPresentationModule
        context.homeModules = Set(homePanels.compactMap { $0.module.map(ActiveModule.builtIn) })
        return context.isVisible(module)
    }

    // MARK: - State Transitions

    /// Automatic hints never navigate a held activity, an open workspace or
    /// controls under the pointer. Remember only actionable reminders.
    func presentEvent(_ event: IslandEventKind) {
        guard isModuleEnabled(event.module), presentationPreferences[event].enabled else { return }
        if (currentState == .fullExpanded && fullExpandedSelectedTab == .module(.builtIn(event.module))) ||
            (currentState == .expanded && activeModule == .builtIn(event.module)) {
            clearPendingEvents(for: event.module)
            if transientHUD == .builtIn(event.module) { scheduleAutoDismiss(after: presentationPreferences[event].duration) }
            return
        }
        if currentState == .fullExpanded || presentationHoldModule != nil || isShelfDragActive || isControlInteractionActive || !presentationHandoffs.isEmpty || isHovering {
            if event.remembersWhileBusy, !pendingIslandEvents.contains(event) { pendingIslandEvents.append(event) }
            return
        }
        pendingIslandEvents.removeAll { $0 == event }
        showHUD(module: event.module, autoDismissDelay: presentationPreferences[event].duration)
    }

    func viewPendingEvent(_ event: IslandEventKind) {
        pendingIslandEvents.removeAll { $0 == event }
        guard isModuleEnabled(event.module) else { return }
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        withAnimation(notchAnimation) {
            selectFullExpandedTab(.module(.builtIn(event.module)))
            currentState = .fullExpanded
        }
    }

    func clearPendingEvents(for module: ModuleType) {
        pendingIslandEvents.removeAll { $0.module == module }
    }

    func toggleExpansion() {
        switch currentState {
        case .compact:
            open()
        case .expanded:
            withAnimation(notchAnimation) {
                currentState = .fullExpanded
            }
        case .fullExpanded:
            dismiss()
        }
    }

    func expand() {
        guard currentState == .compact else { return }
        supersedePresentationIntent()
        withAnimation(notchAnimation) {
            currentState = .expanded
        }
    }

    func open() {
        guard !isKeyboardCleaningActive else { return }
        supersedePresentationIntent()
        guard currentState != .fullExpanded else { return }

        prepareFullExpandedPresentation(prefersHome: currentState == .compact)
        cancelAutoDismiss()
        cancelFullExpandedDismiss()

        withAnimation(notchAnimation) {
            currentState = .fullExpanded
        }
    }

    func fullyExpand() {
        guard !isKeyboardCleaningActive else { return }
        supersedePresentationIntent()
        prepareFullExpandedPresentation(prefersHome: false)
        withAnimation(notchAnimation) {
            currentState = .fullExpanded
        }
    }

    /// Explicit music navigation shared by compact clicks and the Home card.
    func presentNowPlaying() {
        presentFullExpandedModule(.nowPlaying)
    }

    func presentAgentAttentionIfAvailable() {
        guard agentEnabled, !isControlInteractionActive, !isHovering,
              presentationHoldModule == nil, presentationHandoffs.isEmpty, !isShelfDragActive,
              currentState != .fullExpanded else { return }
        presentFullExpandedModule(.agent)
    }

    @Published private(set) var agentPanelContentHeight: CGFloat = 220

    func updateAgentPanelContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        let next = max(100, ceil(height))
        guard abs(next - agentPanelContentHeight) > 0.5 else { return }
        // Content supplies its final natural height, never animated estimates.
        // Only the host interpolates the resulting viewport, without bounce.
        withAnimation(motion.resize) { agentPanelContentHeight = next }
    }

    func presentFullExpandedModule(_ module: ModuleType) {
        guard !isKeyboardCleaningActive else { return }
        guard isModuleEnabled(module) else { return }
        supersedePresentationIntent()
        beginCompactControlInteraction()
        cancelHoverActivation()
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        // Choose the target page and surface in one transaction. Selecting a
        // module through the navigation helper would first enter .expanded.
        withAnimation(notchAnimation) {
            finishTransientHUD()
            previousModule = activeModule
            activeModule = .builtIn(module)
            explicitlySelectedModule = .builtIn(module)
            fullExpandedSelectedTab = .module(.builtIn(module))
            currentState = .fullExpanded
        }
    }

    var canHandleIslandSurfaceGesture: Bool {
        !isControlInteractionActive && !isSystemEmojiInteractionActive && handoffSurfaceEvent == nil
    }

    func dismiss() {
        guard !isKeyboardCleaningActive else { return }
        if isShelfDragActive || isControlInteractionActive {
            cancelAutoDismiss()
            cancelFullExpandedDismiss()
            cancelHoverActivation()
            return
        }
        if currentState == .fullExpanded, lockFullExpandedInPlace {
            cancelFullExpandedDismiss()
            return
        }
        collapseIsland()
    }

    private func collapseIsland() {
        pointerMovementResetRequested?()
        hoverActivationAwaitsMovement = isHovering
        presentationRevision = UUID()
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        cancelHoverActivation()
        endSystemEmojiInteraction()
        withAnimation(motion.collapse) {
            finishTransientHUD()
            explicitlySelectedModule = nil
            activeModule = presentationHoldModule
            shelfDefaultToShelf = false
            currentState = .compact
        }
    }

    private func finishTransientHUD() {
        guard let transientHUD else { return }
        cancelAutoDismiss()
        if activeModule == transientHUD {
            activeModule = moduleBeforeHUD.flatMap { module in
                if case .builtIn(let builtIn) = module, isModuleEnabled(builtIn) { return module }
                return nil
            }
        }
        self.transientHUD = nil
        moduleBeforeHUD = nil
    }

    func holdPresentation(for module: ActiveModule) {
        objectWillChange.send()
        presentationHoldModule = module
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        cancelHoverActivation()
        refreshScheduler?.refreshScheduling()
    }

    func releasePresentationHold(for module: ActiveModule) {
        guard presentationHoldModule == module else { return }
        objectWillChange.send()
        presentationHoldModule = nil
        refreshScheduler?.refreshScheduling()
        resumeDismissAfterInteraction()
    }

    func handleHoverChange(_ hovering: Bool) {
        let wasHovering = isHovering
        if hovering != wasHovering { isHovering = hovering }
        if !hovering { hoverActivationAwaitsMovement = false }
        if hovering && !wasHovering { performNotchEntryHapticIfNeeded() }
        reconcileIslandInteraction()
    }

    func handlePointerSample(hovering: Bool, moved: Bool, leftButtonDown: Bool? = nil) {
        // A proven physical release ends all targets of that drag, even if a
        // native drag loop omitted mouse-up or SwiftUI never sent target-exit.
        // Import completion remains independent and never releases these holds.
        if leftButtonDown == false, isShelfDragActive { cancelShelfDragPresentation() }
        if moved { hoverActivationAwaitsMovement = false }
        handleHoverChange(hovering)
    }

    func setPointerInputAvailable(_ available: Bool) {
        pointerInputAvailable = available
        if !available {
            if isHovering { isHovering = false }
            hoverActivationAwaitsMovement = false
        }
        reconcileIslandInteraction()
    }

    /// All input and protection-release paths converge here. Repeated samples
    /// preserve pending deadlines instead of continually postponing them.
    func reconcileIslandInteraction() {
        guard pointerInputAvailable, !isShelfDragActive, !isControlInteractionActive,
              !isKeyboardCleaningActive, !isSystemEmojiInteractionActive else {
            cancelAutoDismiss()
            cancelFullExpandedDismiss()
            cancelHoverActivation()
            return
        }
        if isHovering {
            cancelAutoDismiss()
            cancelFullExpandedDismiss()
            if currentState == .fullExpanded || hoverActivationAwaitsMovement {
                cancelHoverActivation()
            } else if hoverActivationWorkItem == nil {
                scheduleHoverActivation()
            }
        } else {
            cancelHoverActivation()
            guard !suppressDismissScheduling else { return }
            if currentState == .expanded, autoDismissWorkItem == nil {
                scheduleAutoDismiss()
            } else if currentState == .fullExpanded, fullExpandedDismissWorkItem == nil {
                scheduleFullExpandedDismiss()
            }
        }
    }

    // MARK: - HUD Management

    func showHUD(module: ModuleType, autoDismiss: Bool = true, autoDismissDelay: TimeInterval? = nil) {
        showHUD(module: .builtIn(module), autoDismiss: autoDismiss, autoDismissDelay: autoDismissDelay)
    }

    func showHUD(module: ActiveModule, autoDismiss: Bool = true, autoDismissDelay: TimeInterval? = nil) {
        guard !isKeyboardCleaningActive else { return }
        if case .builtIn(let builtIn) = module, !isModuleEnabled(builtIn) {
            return
        }
        // Passive events must not replace an open workspace or a held activity.
        if autoDismiss {
            guard presentationHandoffs.isEmpty else { return }
            guard currentState != .fullExpanded, presentationHoldModule == nil, !isShelfDragActive else { return }
            guard !isControlInteractionActive || transientHUD == module else { return }
            guard !isHovering || transientHUD != nil else { return }
            if transientHUD == nil { moduleBeforeHUD = activeModule }
            transientHUD = module
            transientHUDDelay = autoDismissDelay ?? 2.5
        } else {
            finishTransientHUD()
        }

        if shouldDirectlyOpenNotificationsOnHover(for: module) {
            presentNotificationsFullExpanded()
            return
        }

        cancelAutoDismiss()

        withAnimation(notchAnimation) {
            activeModule = module
            if currentState == .compact {
                currentState = .expanded
            }
        }

        if autoDismiss {
            scheduleAutoDismiss(after: autoDismissDelay)
        } else {
            cancelAutoDismiss()
        }
    }

    func scheduleAutoDismiss(after delayOverride: TimeInterval? = nil) {
        cancelAutoDismiss()
        guard pointerInputAvailable, !suppressDismissScheduling else { return }
        guard !isControlInteractionActive else { return }
        guard !isHovering else { return }
        guard !isShelfDragActive else { return }
        guard !isSystemEmojiInteractionActive else { return }
        guard !isPresentationHeld(activeModule) else { return }
        let delay = delayOverride ?? (transientHUD != nil ? transientHUDDelay : expandedAutoDismissDelay)
        guard delay > 0 else { return }
        let generation = autoDismissGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.autoDismissGeneration == generation else { return }
            self.autoDismissWorkItem = nil
            guard self.currentState == .expanded, !self.isHovering, self.pointerInputAvailable,
                  !self.suppressDismissScheduling, !self.isSystemEmojiInteractionActive,
                  !self.isPresentationHeld(self.activeModule) else { return }
            self.dismiss()
        }
        autoDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + delay,
            execute: workItem
        )
    }

    func cancelAutoDismiss() {
        autoDismissGeneration = UUID()
        autoDismissWorkItem?.cancel()
        autoDismissWorkItem = nil
    }

    func scheduleFullExpandedDismiss() {
        cancelFullExpandedDismiss()
        guard pointerInputAvailable, !suppressDismissScheduling, !isHovering else { return }
        guard !isControlInteractionActive else { return }
        guard !isShelfDragActive else { return }
        guard !(currentState == .fullExpanded && lockFullExpandedInPlace) else { return }
        guard !isSystemEmojiInteractionActive else { return }
        guard !isPresentationHeld(fullExpandedSelectedModule) else { return }
        let delay = expandedAutoDismissDelay
        guard delay > 0 else { return }
        let generation = fullExpandedDismissGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.fullExpandedDismissGeneration == generation else { return }
            self.fullExpandedDismissWorkItem = nil
            guard self.currentState == .fullExpanded, !self.isHovering, self.pointerInputAvailable,
                  !self.suppressDismissScheduling, !self.isSystemEmojiInteractionActive,
                  !self.isPresentationHeld(self.fullExpandedSelectedModule) else { return }
            self.dismiss()
        }
        fullExpandedDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelFullExpandedDismiss() {
        fullExpandedDismissGeneration = UUID()
        fullExpandedDismissWorkItem?.cancel()
        fullExpandedDismissWorkItem = nil
    }

    func toggleFullExpandedLock() {
        lockFullExpandedInPlace.toggle()

        if lockFullExpandedInPlace {
            cancelFullExpandedDismiss()
            return
        }

        guard currentState == .fullExpanded,
              !isHovering,
              !suppressDismissScheduling,
              !isShelfDragActive,
              !isSystemEmojiInteractionActive else {
            return
        }

        scheduleFullExpandedDismiss()
    }

    func cancelHoverActivation() {
        hoverActivationGeneration = UUID()
        hoverActivationWorkItem?.cancel()
        hoverActivationWorkItem = nil
    }

    var isSystemEmojiInteractionActive: Bool {
        guard let expiry = systemEmojiInteractionExpiry else { return false }
        return expiry > Date()
    }

    func beginSystemEmojiInteraction(timeout: TimeInterval = 12) {
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        cancelHoverActivation()

        let expiry = Date().addingTimeInterval(timeout)
        systemEmojiInteractionExpiry = expiry
        systemEmojiInteractionWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.systemEmojiInteractionExpiry == expiry else { return }
            self.systemEmojiInteractionExpiry = nil
            self.systemEmojiInteractionWorkItem = nil

            self.resumeDismissAfterInteraction()
        }

        systemEmojiInteractionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    func beginCompactControlInteraction(timeout: TimeInterval = 1.2) {
        beginSystemEmojiInteraction(timeout: timeout)
    }

    func endSystemEmojiInteraction() {
        systemEmojiInteractionWorkItem?.cancel()
        systemEmojiInteractionWorkItem = nil
        systemEmojiInteractionExpiry = nil
    }

    private func collapseForHandoff() {
        if currentState != .fullExpanded || !lockFullExpandedInPlace { collapseIsland() }
    }

    func updatePresentationContext(screen: NSScreen?) {
        guard let screen else {
            presentationScreenFrame = .zero
            presentationVisibleFrame = .zero
            presentationHasNotch = false
            presentationNotchRect = nil
            return
        }

        presentationScreenFrame = screen.frame
        presentationVisibleFrame = screen.visibleFrame
        presentationHasNotch = ScreenDetector.hasNotch(screen: screen)
        presentationNotchRect = ScreenDetector.notchRect(screen: screen)
    }

    private func scheduleHoverActivation() {
        guard pointerInputAvailable, !hoverActivationAwaitsMovement else { return }
        guard !isSystemEmojiInteractionActive else { return }

        cancelHoverActivation()

        let startingState = currentState
        let generation = hoverActivationGeneration
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.hoverActivationGeneration == generation else { return }
            self.hoverActivationWorkItem = nil
            guard self.pointerInputAvailable, self.isHovering, self.currentState != .fullExpanded,
                  !self.hoverActivationAwaitsMovement, !self.isControlInteractionActive,
                  !self.isShelfDragActive, !self.isKeyboardCleaningActive,
                  !self.isSystemEmojiInteractionActive else { return }

            if self.shouldHoverExpandNotifications(from: startingState) {
                self.presentNotificationsFullExpanded()
                return
            }

            if self.compactPresentationModule == .builtIn(.nowPlaying) {
                self.presentNowPlaying()
                return
            }
            if self.compactPresentationModule == .builtIn(.agent) {
                self.presentFullExpandedModule(.agent)
                return
            }

            self.open()
        }

        hoverActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + hoverExpandDelay,
            execute: workItem
        )
    }

    private func shouldHoverExpandNotifications(from startingState: IslandState) -> Bool {
        guard startingState == .compact || startingState == .expanded,
              activeBuiltInModule == .notifications,
              hasFreshNotificationForHover else {
            return false
        }
        return true
    }

    private func shouldDirectlyOpenNotificationsOnHover(for module: ActiveModule) -> Bool {
        guard currentState != .fullExpanded,
              isHover,
              case .builtIn(.notifications) = module,
              hasFreshNotificationForHover else {
            return false
        }

        return true
    }

    private var hasFreshNotificationForHover: Bool {
        guard let notification = NotificationManager.shared.latestNotification else {
            return false
        }

        return Date().timeIntervalSince(notification.timestamp) <= Constants.notificationHoverFullExpandWindow
    }

    private var isHover: Bool {
        isHovering
    }

    private var fullExpandedSelectedModule: ActiveModule? {
        guard case .module(let module) = fullExpandedSelectedTab else { return nil }
        return module
    }

    private func isPresentationHeld(_ module: ActiveModule?) -> Bool {
        guard let module, let presentationHoldModule else { return false }
        return module == presentationHoldModule
    }

    private func handleStateTransition(from oldValue: IslandState, to newValue: IslandState) {
        guard oldValue != newValue else { return }

        switch newValue {
        case .expanded:
            cancelFullExpandedDismiss()
            if !suppressDismissScheduling && !isShelfDragActive {
                scheduleAutoDismiss()
            }
        case .compact, .fullExpanded:
            cancelAutoDismiss()
            if newValue == .compact {
                cancelFullExpandedDismiss()
            }
        }
    }

    // MARK: - Module Cycling

    func cycleModule(forward: Bool) {
        guard !isKeyboardCleaningActive else { return }
        finishTransientHUD()
        if currentState == .fullExpanded {
            cycleFullExpandedTab(forward: forward)
            return
        }

        let modules = availableModules
        guard !modules.isEmpty else { return }

        let nextModule: ActiveModule
        if let activeModule, let index = modules.firstIndex(of: activeModule) {
            let nextIndex = forward
                ? modules.index(after: index) % modules.count
                : (index - 1 + modules.count) % modules.count
            nextModule = modules[nextIndex]
        } else if forward {
            nextModule = modules[0]
        } else {
            nextModule = modules[modules.count - 1]
        }

        setActiveModule(nextModule, userInitiated: true)
    }

    func setActiveModule(_ module: ModuleType, userInitiated: Bool = false) {
        setActiveModule(.builtIn(module), userInitiated: userInitiated)
    }

    func setActiveModule(_ module: ActiveModule, userInitiated: Bool = false) {
        guard !isKeyboardCleaningActive else { return }
        if userInitiated { supersedePresentationIntent() }
        // Media updates refresh content without navigating away from an open page or HUD.
        if module == .builtIn(.nowPlaying), !userInitiated,
           currentState != .compact || transientHUD != nil { return }
        if case .builtIn(let builtIn) = module, !isModuleEnabled(builtIn) {
            return
        }
        if transientHUD != nil {
            if !userInitiated {
                moduleBeforeHUD = module
                return
            }
            finishTransientHUD()
            cancelAutoDismiss()
        }
        withAnimation(contentSwapAnimation) {
            previousModule = activeModule
            activeModule = module
            if userInitiated {
                explicitlySelectedModule = module
                if currentState == .compact { currentState = .expanded }
            }
        }
    }

    func selectFullExpandedTab(_ tab: FullExpandedTab) {
        guard !isKeyboardCleaningActive else { return }
        supersedePresentationIntent()
        finishTransientHUD()
        if tab == .home { explicitlySelectedModule = nil }
        withAnimation(contentSwapAnimation) {
            fullExpandedSelectedTab = tab
        }

        updateShelfDefaultSelection(for: tab)

        if case .module(let module) = tab {
            if case .builtIn(let builtIn) = module { clearPendingEvents(for: builtIn) }
            setActiveModule(module, userInitiated: true)
        }
    }

    func showHomeTab() {
        guard !isKeyboardCleaningActive else { return }
        supersedePresentationIntent()
        finishTransientHUD()
        explicitlySelectedModule = nil
        withAnimation(contentSwapAnimation) {
            fullExpandedSelectedTab = .home
        }
        shelfDefaultToShelf = false
    }

    // MARK: - Module Status

    /// Settings changes must not leave a disabled module selected or on screen.
    func reconcileEnabledModules() {
        for session in presentationHandoffs.values where session.module.map({ !isModuleEnabled($0) }) == true {
            finishPresentationHandoff(session, outcome: .cancelled)
        }
        for token in controlInteractions where token.module.map({ !isModuleEnabled($0) }) == true {
            endControlInteraction(token)
        }
        if case .builtIn(let module) = transientHUD, !isModuleEnabled(module) {
            finishTransientHUD()
            cancelAutoDismiss()
        }
        if case .builtIn(let module) = explicitlySelectedModule, !isModuleEnabled(module) {
            explicitlySelectedModule = nil
        }
        if case .builtIn(let module) = presentationHoldModule, !isModuleEnabled(module) {
            presentationHoldModule = nil
        }
        if case .builtIn(let module) = previousModule, !isModuleEnabled(module) {
            previousModule = nil
        }
        if case .builtIn(let module) = activeModule, !isModuleEnabled(module) {
            cancelAutoDismiss()
            activeModule = nil
        }
        if case .module(let module) = fullExpandedSelectedTab,
           !canPresentFullExpandedModule(module) {
            fullExpandedSelectedTab = .home
        }
        resumeDismissAfterInteraction()
    }

    /// Single settings entry point. Module activation is distinct from granting
    /// system permissions and never deletes the module's saved data.
    func setModuleEnabled(_ module: ModuleType, enabled: Bool) {
        guard isModuleEnabled(module) != enabled else { return }
        guard moduleEnablementWillChange?(module, enabled) != false else { return }
        // AppStorage nested in an ObservableObject does not forward view invalidation.
        objectWillChange.send()
        if !enabled { clearPendingEvents(for: module) }
        switch module {
        case .nowPlaying: nowPlayingEnabled = enabled
        case .volumeHUD: volumeHUDEnabled = enabled
        case .battery: batteryEnabled = enabled
        case .shelf:
            shelfEnabled = enabled
            if !enabled { cancelShelfDragPresentation() }
        case .connectivity: connectivityEnabled = enabled
        case .calendar: calendarEnabled = enabled
        case .weather: weatherEnabled = enabled
        case .notifications: notificationsEnabled = enabled
        case .teleprompter: teleprompterEnabled = enabled
        case .agent: agentEnabled = enabled
        case .tools: toolsEnabled = enabled
        }
        reconcileEnabledModules()
        moduleEnablementDidChange?()
        refreshEnergyState()
    }

    func isModuleEnabled(_ module: ModuleType) -> Bool {
        switch module {
        case .nowPlaying: return nowPlayingEnabled
        case .volumeHUD: return volumeHUDEnabled
        case .battery: return batteryEnabled
        case .shelf: return shelfEnabled
        case .connectivity: return connectivityEnabled
        case .calendar: return calendarEnabled
        case .weather: return weatherEnabled
        case .notifications: return notificationsEnabled
        case .teleprompter: return teleprompterEnabled
        case .agent: return agentEnabled
        case .tools: return toolsEnabled
        }
    }

    var activeBuiltInModule: ModuleType? {
        guard case .builtIn(let module) = activeModule else {
            return nil
        }
        return module
    }

    private func isCyclableIslandModule(_ module: ModuleType) -> Bool {
        switch module {
        case .volumeHUD, .battery:
            return false
        default:
            return true
        }
    }

    var availableModules: [ActiveModule] {
        let builtIns = orderedModules
            .filter { isCyclableIslandModule($0) && isModuleEnabled($0) }
            .map(ActiveModule.builtIn)
        return builtIns
    }

    var fullExpandedModules: [ActiveModule] {
        let builtIns = orderedModules
            .filter { isCyclableIslandModule($0) && supportsFullExpandedModule(.builtIn($0)) && isModuleEnabled($0) }
            .map(ActiveModule.builtIn)
        return builtIns
    }

    var fullExpandedTabs: [FullExpandedTab] {
        var tabs: [FullExpandedTab] = [.home]
        tabs.append(contentsOf: fullExpandedModules.map(FullExpandedTab.module))
        return tabs
    }

    /// Navigation order is independent of event interruption and presentation priority.
    var orderedModules: [ModuleType] { ModuleOrder.resolve(moduleOrderRaw) }

    /// Apply an insertion offset measured before the moved module is removed.
    func moveModules(from source: IndexSet, to destination: Int) {
        let modules = orderedModules
        guard source.count == 1, let index = source.first, modules.indices.contains(index),
              (0...modules.count).contains(destination) else { return }
        let target = destination > index ? destination - 1 : destination
        guard modules.indices.contains(target), index != target else { return }
        moveModule(modules[index], to: modules[target])
    }

    func moveModule(_ module: ModuleType, to target: ModuleType) {
        var modules = orderedModules
        guard let source = modules.firstIndex(of: module),
              let destination = modules.firstIndex(of: target), source != destination else { return }
        modules.remove(at: source)
        modules.insert(module, at: destination)
        objectWillChange.send()
        moduleOrderRaw = modules.map(\.rawValue).joined(separator: ",")
    }

    func moveModule(_ module: ModuleType, by offset: Int) {
        let modules = orderedModules
        guard let index = modules.firstIndex(of: module), modules.indices.contains(index + offset) else { return }
        moveModule(module, to: modules[index + offset])
    }

    var hasFullExpandedShoulderBarSpace: Bool {
        currentState == .fullExpanded && currentContentTopInset > 0 && fullExpandedShoulderGapWidth > 0
    }

    var fullExpandedShoulderGapWidth: CGFloat {
        guard let notch = currentNotchRect else {
            return 0
        }

        let minimumGap = notch.width + 20
        let maximumGap = max(160, contentSize(for: .fullExpanded).width * 0.42)
        return min(maximumGap, minimumGap)
    }

    /// Shared by compact content and sizing so the two never select different modules.
    var compactPresentationModule: ActiveModule? {
        let nowPlaying = nowPlayingEnabled ? NowPlayingManager.shared : nil
        let hasMedia = nowPlayingEnabled && (currentState != .compact || compactMusicEnabled) && (
            nowPlaying.map { !$0.title.isEmpty || $0.albumArt != nil || !$0.sourceName.isEmpty } == true
        )
        return CompactModuleSelection.resolve(
            active: activeModule,
            explicitSelection: explicitlySelectedModule,
            presentationHold: presentationHoldModule,
            hasVerifiedAgentAttention: agentEnabled && AgentManager.shared.attentionCount > 0,
            hasMedia: hasMedia,
            mediaIsPlaying: nowPlaying?.isEligibleForCompactPresentation == true,
            batteryEnabled: batteryEnabled,
            isCompact: currentState == .compact,
            idleModule: presentationPreferences.idleContent.module.flatMap { isModuleEnabled($0) ? .builtIn($0) : nil },
            hasVerifiedAgentActivity: agentEnabled && AgentManager.shared.groups.contains { AgentManager.shared.interaction.liveSessionIDs.contains($0.id) && $0.status == .running },
            isKeepingAwake: toolsEnabled && isKeepAwakeActive
        )
    }

    var shouldUseMinimalCompactLayout: Bool {
        guard presentationHasNotch,
              !hideSideSlots,
              let module = compactPresentationModule else {
            return false
        }

        return supportsMinimalCompactLayout(module)
    }

    var compactMinimalCenterGapWidth: CGFloat {
        presentationNotchRect?.width ?? compactBaseSize.width
    }

    var compactSideSlotWidth: CGFloat { compactSideLayout.contentWidth }
    var compactSideCornerInset: CGFloat {
        shouldUseMinimalCompactLayout && usesOutwardTopCorners ? compactSideLayout.cornerInset : 0
    }

    // MARK: - Size Helpers

    var currentSize: CGSize {
        size(for: currentState)
    }

    var currentContentSize: CGSize {
        contentSize(for: currentState)
    }

    func size(for state: IslandState) -> CGSize {
        let contentSize = self.contentSize(for: state)
        // On non-notch Macs the outward arch insets walls by the top
        // corner radius — widen the surface so the inner wall-to-wall
        // width matches the content frame.
        let archWidthBoost: CGFloat = state == .compact && shouldUseMinimalCompactLayout
            ? compactSideCornerInset * 2
            : usesOutwardTopCorners && !presentationHasNotch
            ? topCornerRadius(for: state) * 2
            : 0
        switch state {
        case .compact:
            return CGSize(
                width: contentSize.width + archWidthBoost,
                height: contentSize.height
            )
        case .expanded, .fullExpanded:
            return CGSize(
                width: contentSize.width + archWidthBoost,
                height: contentSize.height + contentTopInset(for: state)
            )
        }
    }

    /// Whether the compact view has room to show extra info (e.g. song title).
    var usesWideCompactLayout: Bool {
        !presentationHasNotch
    }

    func contentSize(for state: IslandState) -> CGSize {
        switch state {
        case .compact:
            if usesWideCompactLayout {
                return Constants.nonNotchCompactSize
            }
            let baseSize = compactBaseSize
            guard shouldUseMinimalCompactLayout else {
                return baseSize
            }

            return CGSize(
                width: compactMinimalCenterGapWidth + (compactSideSlotWidth * 2),
                height: baseSize.height
            )
        case .expanded:
            return Constants.expandedSize
        case .fullExpanded:
            let base = Constants.fullExpandedSize
            let inlineToolbar = usesOutwardTopCorners && !presentationHasNotch
            if fullExpandedSelectedTab == .module(.builtIn(.agent)), agentEnabled {
                let preferred = agentPanelContentHeight
                let available: CGFloat? = presentationScreenFrame == .zero ? nil
                    : presentationScreenFrame.maxY - presentationVisibleFrame.minY - contentTopInset(for: state) - Constants.expandedShadowBottomPadding - 12
                return CGSize(width: base.width, height: FullExpandedLayout.agentContentHeight(
                    measuredHeight: preferred, inlineToolbar: inlineToolbar, availableHeight: available))
            }
            if fullExpandedSelectedTab == .module(.builtIn(.shelf)), shelfEnabled {
                let available = presentationScreenFrame == .zero ? nil
                    : presentationScreenFrame.maxY - presentationVisibleFrame.minY
                        - contentTopInset(for: state) - Constants.expandedShadowBottomPadding - 12
                return CGSize(width: base.width, height: FullExpandedLayout.shelfContentHeight(
                    inlineToolbar: inlineToolbar, availableHeight: available))
            }
            // On non-notch Macs the toolbar is inline (no shoulder area),
            // so reserve its 50pt plus the extra 8pt top padding (12 vs 4).
            if inlineToolbar {
                return CGSize(width: base.width, height: base.height + FullExpandedLayout.inlineHeightBoost)
            }
            return base
        }
    }

    var windowSize: CGSize {
        windowSize(for: currentState)
    }

    func windowSize(for state: IslandState) -> CGSize {
        let islandSize = size(for: state)
        switch state {
        case .compact:
            // Window must be exactly island-sized so the transparent area
            // outside the pill doesn't absorb clicks (see issue #1 / #15).
            // The viewport stays expanded until the surface animation's
            // completion callback releases it; no extra compact buffer is needed.
            return CGSize(
                width: islandSize.width,
                height: islandSize.height
            )
        case .expanded, .fullExpanded:
            return CGSize(
                width: islandSize.width + (Constants.expandedShadowHorizontalPadding * 2),
                height: islandSize.height + Constants.expandedShadowBottomPadding
            )
        }
    }

    var currentCornerRadius: CGFloat {
        switch currentState {
        case .compact: return currentBottomCornerRadius
        case .expanded: return Constants.expandedCornerRadius
        case .fullExpanded: return Constants.fullExpandedBottomCornerRadius
        }
    }

    var currentTopLeadingCornerRadius: CGFloat {
        if shouldUseSquaredTopCorners {
            return notchedExpandedShoulderRadius
        }
        return currentTopCornerRadius
    }

    var currentTopTrailingCornerRadius: CGFloat {
        if shouldUseSquaredTopCorners {
            return notchedExpandedShoulderRadius
        }
        return currentTopCornerRadius
    }

    var currentBottomLeadingCornerRadius: CGFloat {
        currentBottomCornerRadius
    }

    var currentBottomTrailingCornerRadius: CGFloat {
        currentBottomCornerRadius
    }

    var currentTopCornerRadius: CGFloat {
        switch currentState {
        case .compact:
            if shouldUseMinimalCompactLayout { return compactSideCornerInset }
            return compactIslandMetrics?.bottomCornerRadius ?? Constants.compactCornerRadius
        case .expanded:
            return Constants.expandedCornerRadius
        case .fullExpanded:
            return Constants.fullExpandedCornerRadius
        }
    }

    var currentBottomCornerRadius: CGFloat {
        switch currentState {
        case .compact:
            return compactIslandMetrics?.bottomCornerRadius ?? Constants.compactCornerRadius
        case .expanded:
            return Constants.expandedCornerRadius
        case .fullExpanded:
            return Constants.fullExpandedBottomCornerRadius
        }
    }

    var currentTopCutoutWidth: CGFloat {
        0
    }

    var currentTopCutoutDepth: CGFloat {
        0
    }

    var currentTopCutoutCornerRadius: CGFloat {
        0
    }

    var currentContentTopInset: CGFloat {
        contentTopInset(for: currentState)
    }

    var currentContentFrameHeight: CGFloat {
        currentContentSize.height
    }

    var contentHorizontalPadding: CGFloat {
        switch currentState {
        case .compact:
            return 0
        case .expanded:
            return 26
        case .fullExpanded:
            return 32
        }
    }

    var contentTopPadding: CGFloat {
        switch currentState {
        case .compact:
            return 0
        case .expanded:
            return 8
        case .fullExpanded:
            return hasFullExpandedShoulderBarSpace ? FullExpandedLayout.shoulderTopPadding : FullExpandedLayout.inlineTopPadding
        }
    }

    var contentBottomPadding: CGFloat {
        switch currentState {
        case .compact:
            return 0
        case .expanded:
            return 10
        case .fullExpanded:
            return FullExpandedLayout.bottomPadding
        }
    }

    var expandedContentScale: CGFloat {
        guard currentState == .expanded, shouldUseSquaredTopCorners else {
            return 1
        }
        return 0.95
    }

    var expandedContentTopOffset: CGFloat {
        guard currentState == .expanded, shouldUseSquaredTopCorners else {
            return 0
        }
        return 4
    }

    private var compactBaseSize: CGSize {
        compactIslandMetrics?.size ?? CGSize(
            width: compactIslandWidth,
            height: compactIslandHeight
        )
    }

    private let compactSideLayout = CompactSideLayout()

    private var compactIslandMetrics: ScreenDetector.CompactIslandMetrics? {
        guard let notch = presentationNotchRect else {
            return nil
        }

        return ScreenDetector.compactIslandMetrics(notch: notch,
            requestedSize: CGSize(width: compactIslandWidth, height: compactIslandHeight))
    }

    var usesOutwardTopCorners: Bool {
        true
    }

    private var shouldUseSquaredTopCorners: Bool {
        shouldUseSquaredTopCorners(for: currentState)
    }

    private func contentTopInset(for state: IslandState) -> CGFloat {
        guard shouldUseSquaredTopCorners(for: state), let notch = currentNotchRect else {
            return 0
        }
        return notch.height + Constants.expandedNotchHeightBoost
    }

    private func topCornerRadius(for state: IslandState) -> CGFloat {
        switch state {
        case .compact:
            let base = compactIslandMetrics?.bottomCornerRadius ?? Constants.compactCornerRadius
            // Clamp to half the compact height (shape does the same internally).
            let height = contentSize(for: .compact).height
            return min(base, height / 2)
        case .expanded:
            return Constants.expandedCornerRadius
        case .fullExpanded:
            return Constants.fullExpandedCornerRadius
        }
    }

    private func shouldUseSquaredTopCorners(for state: IslandState) -> Bool {
        state != .compact && presentationHasNotch
    }

    private var notchedExpandedShoulderRadius: CGFloat {
        guard let notch = presentationNotchRect else {
            return currentTopCornerRadius
        }

        let targetRadius = (notch.height + Constants.expandedNotchHeightBoost) / 2
        return min(currentBottomCornerRadius, max(Constants.compactNotchBottomCornerRadius, targetRadius))
    }

    private var currentNotchRect: NSRect? {
        presentationNotchRect
    }

    private func performNotchEntryHapticIfNeeded() {
        guard presentationHasNotch,
              currentState == .compact,
              Date().timeIntervalSince(lastNotchEntryHapticDate) > 0.6 else {
            return
        }

        let intensity = NotchHapticIntensity(rawValue: notchHapticIntensity) ?? .medium
        guard intensity != .off else { return }

        lastNotchEntryHapticDate = Date()
        HapticFeedbackController.play(sequence: intensity.feedbackSequence)
    }

    private func prepareFullExpandedPresentation(prefersHome: Bool) {
        let nextTab: FullExpandedTab

        if let presentationHoldModule {
            nextTab = .module(presentationHoldModule)
        } else if shouldDefaultToShelf {
            nextTab = .module(.builtIn(.shelf))
        } else if prefersHome {
            nextTab = .home
        } else if let activeModule, supportsFullExpandedModule(activeModule) {
            nextTab = .module(activeModule)
        } else {
            nextTab = .home
        }

        if fullExpandedSelectedTab != nextTab {
            fullExpandedSelectedTab = nextTab
        }

        if case .module(let module) = nextTab {
            previousModule = activeModule
            activeModule = module
        }
    }

    private func cycleFullExpandedTab(forward: Bool) {
        let tabs = fullExpandedTabs
        guard !tabs.isEmpty else { return }

        let currentTab = tabs.contains(fullExpandedSelectedTab) ? fullExpandedSelectedTab : .home
        let currentIndex = tabs.firstIndex(of: currentTab) ?? 0
        let nextIndex = forward
            ? tabs.index(after: currentIndex) % tabs.count
            : (currentIndex - 1 + tabs.count) % tabs.count
        let nextTab = tabs[nextIndex]

        withAnimation(contentSwapAnimation) {
            fullExpandedSelectedTab = nextTab
            if case .module(let module) = nextTab {
                previousModule = activeModule
                activeModule = module
                explicitlySelectedModule = module
            } else {
                explicitlySelectedModule = nil
            }
        }

        updateShelfDefaultSelection(for: nextTab)
    }

    private func supportsFullExpandedModule(_ module: ActiveModule) -> Bool {
        switch module {
        default:
            return true
        }
    }

    private func supportsMinimalCompactLayout(_ module: ActiveModule) -> Bool {
        switch module {
        case .builtIn(.nowPlaying), .builtIn(.agent), .builtIn(.tools):
            return true
        default:
            return false
        }
    }

    func canPresentFullExpandedModule(_ module: ActiveModule) -> Bool {
        if case .builtIn(let builtIn) = module, !isModuleEnabled(builtIn) { return false }
        switch module {
        case .builtIn(.volumeHUD), .builtIn(.battery), .builtIn(.shelf):
            return true
        default:
            return fullExpandedModules.contains(module)
        }
    }

    func presentShelfAfterDrop() {
        guard !isKeyboardCleaningActive else { return }
        // Import completion may arrive during a later drag. Targets release
        // their own holds; finishing an import must not end another session.
        defer { resumeDismissAfterInteraction() }
        rememberShelfAsDefault()
        guard shelfEnabled, shelfAutoOpenOnDrop, !isShelfDragActive else { return }

        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        previousModule = activeModule
        activeModule = .builtIn(.shelf)
        fullExpandedSelectedTab = .module(.builtIn(.shelf))

        withAnimation(currentState == .compact ? notchAnimation : contentSwapAnimation) {
            currentState = .fullExpanded
        }
    }

    func beginShelfDragPresentation(owner: UUID) {
        guard !isKeyboardCleaningActive else { return }
        guard shelfEnabled else { return }
        shelfDragOwners.insert(owner)
        guard !isShelfDragActive else { return }

        isShelfDragActive = true
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        cancelHoverActivation()

        previousModule = activeModule
        activeModule = .builtIn(.shelf)
        fullExpandedSelectedTab = .module(.builtIn(.shelf))

        withAnimation(currentState == .compact ? notchAnimation : contentSwapAnimation) {
            currentState = .fullExpanded
        }
    }

    var allowsShelfDragApproach: Bool {
        shelfEnabled && shelfExpandOnDragApproach && presentationHandoffs.isEmpty && !isControlInteractionActive
    }

    func cancelShelfDragPresentation() {
        guard isShelfDragActive || !shelfDragOwners.isEmpty else { return }
        shelfDragOwners.removeAll()
        isShelfDragActive = false
    }

    func endShelfDragPresentation(owner: UUID) {
        guard shelfDragOwners.remove(owner) != nil, shelfDragOwners.isEmpty else { return }
        isShelfDragActive = false
        resumeDismissAfterInteraction()
    }

    func presentNotificationsFullExpanded() {
        guard !isKeyboardCleaningActive else { return }
        guard notificationsEnabled, NotificationManager.shared.latestNotification != nil else { return }

        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        cancelHoverActivation()

        previousModule = activeModule
        activeModule = .builtIn(.notifications)
        fullExpandedSelectedTab = .module(.builtIn(.notifications))

        withAnimation(notchAnimation) {
            currentState = .fullExpanded
        }
    }

    func rememberShelfAsDefault() {
        guard shelfEnabled, !ShelfStore.shared.isEmpty else { return }
        shelfDefaultToShelf = true
    }

    private var shouldDefaultToShelf: Bool {
        shelfEnabled && shelfDefaultToShelf && !ShelfStore.shared.isEmpty
    }

    private func updateShelfDefaultSelection(for tab: FullExpandedTab) {
        switch tab {
        case .module(.builtIn(.shelf)):
            shelfDefaultToShelf = !ShelfStore.shared.isEmpty
        default:
            shelfDefaultToShelf = false
        }
    }

}

extension AppState {
    func setKeepAwakeActive(_ active: Bool) {
        isKeepAwakeActive = active
        refreshEnergyState()
    }

    func setKeyboardCleaningActive(_ active: Bool) {
        guard isKeyboardCleaningActive != active else { return }
        if active {
            presentFullExpandedModule(.tools)
            keyboardCleaningInteraction = beginControlInteraction(for: .tools)
        }
        isKeyboardCleaningActive = active
        if !active, let token = keyboardCleaningInteraction {
            keyboardCleaningInteraction = nil
            endControlInteraction(token)
        }
    }

    @discardableResult
    func beginControlInteraction(for module: ModuleType? = nil) -> IslandInteractionToken {
        let token = IslandInteractionToken(module: module)
        controlInteractions.insert(token)
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        cancelHoverActivation()
        return token
    }

    func endControlInteraction(_ token: IslandInteractionToken) {
        guard controlInteractions.remove(token) != nil else { return }
        resumeDismissAfterInteraction()
    }

    /// Call only for an action originating in the island. Menu/launch entries
    /// keep their own window lifecycle without changing island presentation.
    func beginPresentationHandoff(_ kind: IslandHandoffKind, for module: ModuleType? = nil,
                                  returnsToSource: Bool = false, replacing previous: IslandPresentationHandoff? = nil) -> IslandPresentationHandoff? {
        guard !isKeyboardCleaningActive else { return nil }
        guard module.map(isModuleEnabled) ?? true, !isShelfDragActive else { return nil }
        if let previous { presentationHandoffs.removeValue(forKey: previous.id) }
        let tab: FullExpandedTab?
        if returnsToSource, currentState == .fullExpanded { tab = fullExpandedSelectedTab }
        else if returnsToSource, let module,
                fullExpandedSelectedTab == .module(.builtIn(module)) || activeModule == .builtIn(module) { tab = .module(.builtIn(module)) }
        else { tab = nil }
        let session = IslandPresentationHandoff(kind: kind, module: module, returnTab: tab)
        latestHandoffID = session.id
        presentationRevision = UUID()
        cancelHoverActivation()
        cancelAutoDismiss()
        cancelFullExpandedDismiss()
        presentationHandoffs[session.id] = session
        presentationHandoffRevision = UUID()
        // Explicit window handoffs supersede an outgoing popover's hold. Each
        // popover still releases only its own token as its presentation closes.
        if kind != .external { collapseForHandoff() }
        protectHandoffSurfaceEvent()
        return session
    }

    func finishPresentationHandoff(_ session: IslandPresentationHandoff, outcome: IslandHandoffOutcome) {
        guard presentationHandoffs.removeValue(forKey: session.id) != nil else { return }
        let isLatest = latestHandoffID == session.id
        guard isLatest, session.module.map(isModuleEnabled) ?? true else {
            resumeDismissAfterInteraction()
            return
        }
        latestHandoffID = nil
        if session.kind == .external, outcome == .completed { collapseForHandoff() }
        else if presentationHandoffs.isEmpty, let tab = session.returnTab,
                outcome == .completed || (session.kind == .fileSelection && outcome == .cancelled) {
            switch tab {
            case .home: open(); showHomeTab()
            case .module(.builtIn(let module)): presentFullExpandedModule(module)
            }
        }
        resumeDismissAfterInteraction()
    }

    func isPresentationHandoffActive(_ session: IslandPresentationHandoff) -> Bool {
        presentationHandoffs[session.id] != nil
    }

    @discardableResult
    func performExternalAction(for module: ModuleType, action: () -> Bool) -> Bool {
        guard let session = beginPresentationHandoff(.external, for: module) else { return false }
        let succeeded = action()
        finishPresentationHandoff(session, outcome: succeeded ? .completed : .failed)
        return succeeded
    }

    @discardableResult
    func openExternalURL(_ url: URL, for module: ModuleType) -> Bool {
        performExternalAction(for: module) { NSWorkspace.shared.open(url) }
    }

    func openExternalApplication(at url: URL, for module: ModuleType,
                                 isCurrent: @escaping () -> Bool, completion: @escaping (Bool) -> Void = { _ in }) {
        guard let session = beginPresentationHandoff(.external, for: module) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { application, error in
            Task { @MainActor in
                let valid = isCurrent()
                let succeeded = application != nil && error == nil
                self.finishPresentationHandoff(session, outcome: valid && succeeded ? .completed : .failed)
                if valid { completion(succeeded) }
            }
        }
    }

    private func resumeDismissAfterInteraction() {
        pointerSamplingRequested?()
        reconcileIslandInteraction()
    }

    private func supersedePresentationIntent() {
        latestHandoffID = nil
        presentationRevision = UUID()
    }

    private func protectHandoffSurfaceEvent() {
        let event = UUID()
        handoffSurfaceEvent = event
        DispatchQueue.main.async { [weak self] in
            guard self?.handoffSurfaceEvent == event else { return }
            self?.handoffSurfaceEvent = nil
        }
    }
}
