import Foundation
import Speech
import SwiftUI

enum TeleprompterListeningMode: String, CaseIterable, Identifiable {
    case classic
    case wordTracking

    var id: String { rawValue }

    var label: String {
        switch self {
        case .classic: return L10n.text("Classic")
        case .wordTracking: return L10n.text("Word Tracking")
        }
    }

    var description: String {
        switch self {
        case .classic:
            return L10n.text("Auto-scrolls at a constant speed.")
        case .wordTracking:
            return L10n.text("Highlights words as you read aloud.")
        }
    }

    var iconName: String {
        switch self {
        case .classic: return "arrow.down.circle"
        case .wordTracking: return "text.word.spacing"
        }
    }
}

@MainActor
final class TeleprompterManager: ObservableObject {
    static let shared = TeleprompterManager()
    let speechRecognizer: TeleprompterSpeechRecognizer
    private let requestWordTrackingAccess: () -> Void
    let sessionStore: TeleprompterSessionStore
    private let preferences: UserDefaults
    private let presentationState: AppState
    private let globalShortcuts: TeleprompterShortcutControlling
    @Published private(set) var pendingResumePosition: TeleprompterReadingPosition?
    @Published private(set) var globalShortcutConflict = false
    @Published var globalShortcutsEnabled: Bool { didSet {
        preferences.set(globalShortcutsEnabled, forKey: SettingsDefaults.Teleprompter.globalShortcuts.key)
        updateGlobalShortcuts()
    } }
    @Published var shortcutModifiers: TeleprompterShortcutModifiers { didSet {
        preferences.set(shortcutModifiers.rawValue, forKey: SettingsDefaults.Teleprompter.shortcutModifiers.key)
        updateGlobalShortcuts()
    } }
    @Published var readingGuidePosition: Double { didSet {
        preferences.set(readingGuidePosition, forKey: SettingsDefaults.Teleprompter.guidePosition.key)
    } }
    private var lastPositionSave = Date.distantPast

    // MARK: - Script

    @Published var scriptText: String {
        didSet {
            preferences.set(scriptText, forKey: "teleprompter.script")
            if oldValue != scriptText { paragraphs = TeleprompterParagraph.parse(scriptText); reset() }
        }
    }

    // MARK: - Playback state

    @Published var isPlaying: Bool = false

    /// Non-nil while the 3-2-1 countdown is running.
    @Published private(set) var countdownValue: Int? = nil

    /// True after a reset — next play() will show the countdown.
    private var pendingCountdown: Bool = true

    /// Incremented on reset so views can snap their scroll offset back to 0.
    @Published private(set) var resetToken: UUID = UUID()

    /// Monotonically-increasing cumulative pixel nudge applied by scroll-wheel input.
    /// The view subtracts the previously-consumed value to get the delta for each tick.
    @Published private(set) var scrollNudge: CGFloat = 0
    @Published private(set) var paragraphs: [TeleprompterParagraph] = []
    @Published private(set) var seekRequest = TeleprompterSeekRequest(displayOffset: 0)
    @Published private(set) var classicProgress: Double = 0
    private var classicParagraphOffset = 0
    @Published var columnWidth: Double { didSet { preferences.set(columnWidth, forKey: SettingsDefaults.Teleprompter.columnWidth.key) } }
    @Published var showsReadingGuide: Bool { didSet { preferences.set(showsReadingGuide, forKey: SettingsDefaults.Teleprompter.readingGuide.key) } }
    @Published var countdownSeconds: Int { didSet {
        preferences.set(countdownSeconds, forKey: SettingsDefaults.Teleprompter.countdown.key)
        if isCountingDown { pause(); pendingCountdown = true }
    } }
    var readingProgress: Double {
        if listeningMode == .wordTracking { return min(1, max(0, Double(speechRecognizer.recognizedCharCount) / Double(max(1, wordTrackingDisplayText.count)))) }
        return classicProgress
    }
    var speedDescription: String { listeningMode == .classic ? L10n.format("%.1f pt/s", scrollSpeed) : L10n.text("Voice tracking") }

    @Published var listeningMode: TeleprompterListeningMode {
        didSet {
            if !isReloadingPreferences {
                preferences.set(listeningMode.rawValue, forKey: SettingsDefaults.Teleprompter.listeningMode.key)
            }
            guard oldValue != listeningMode else { return }
            pause()
            pendingCountdown = true
            scrollNudge = 0
            classicProgress = 0
            classicParagraphOffset = 0
            seekRequest = TeleprompterSeekRequest(displayOffset: 0)
            speechRecognizer.reset()
            resetToken = UUID()
            pendingResumePosition = nil
            sessionStore.clearPosition()
            if !isReloadingPreferences, listeningMode == .wordTracking, presentationState.teleprompterEnabled {
                requestWordTrackingAccess()
            }
        }
    }

    // MARK: - Style settings (persisted)

    /// Pixels per second of scroll speed.
    @Published var scrollSpeed: Double {
        didSet { preferences.set(scrollSpeed, forKey: SettingsDefaults.Teleprompter.scrollSpeed.key) }
    }

    /// Font size in points.
    @Published var fontSize: Double {
        didSet { preferences.set(fontSize, forKey: SettingsDefaults.Teleprompter.fontSize.key) }
    }

    /// 0 = leading, 1 = center, 2 = trailing
    @Published var textAlignmentIndex: Int {
        didSet { preferences.set(textAlignmentIndex, forKey: SettingsDefaults.Teleprompter.alignment.key) }
    }

    @Published var speechLocale: String {
        didSet {
            if !isReloadingPreferences {
                preferences.set(speechLocale, forKey: SettingsDefaults.Teleprompter.speechLocaleKey)
            }
            if oldValue != speechLocale { reset() }
        }
    }

    var textAlignment: TextAlignment {
        switch textAlignmentIndex {
        case 0: return .leading
        case 2: return .trailing
        default: return .center
        }
    }

    // MARK: - Private

    private var isReloadingPreferences = false
    private var isEnabled = false
    private var countdownGeneration = UUID()
    private var countdownTimer: Timer?

    init(preferences: UserDefaults = .standard, globalShortcuts: TeleprompterShortcutControlling? = nil, appState: AppState? = nil,
         speechRecognizer: TeleprompterSpeechRecognizer? = nil, requestWordTrackingAccess: (() -> Void)? = nil) {
        self.speechRecognizer = speechRecognizer ?? TeleprompterSpeechRecognizer()
        self.requestWordTrackingAccess = requestWordTrackingAccess ?? { PermissionsManager.shared.requestTeleprompterWordTrackingAccess() }
        self.preferences = preferences
        self.presentationState = appState ?? .shared
        self.globalShortcuts = globalShortcuts ?? TeleprompterGlobalShortcuts()
        self.sessionStore = TeleprompterSessionStore(preferences: preferences)
        globalShortcutsEnabled = SettingsDefaults.Teleprompter.globalShortcuts.read(from: preferences)
        shortcutModifiers = TeleprompterShortcutModifiers(rawValue: SettingsDefaults.Teleprompter.shortcutModifiers.read(from: preferences)) ?? .controlOption
        readingGuidePosition = min(0.7, max(0.2, SettingsDefaults.Teleprompter.guidePosition.read(from: preferences)))
        columnWidth = min(1, max(0.5, SettingsDefaults.Teleprompter.columnWidth.read(from: preferences)))
        showsReadingGuide = SettingsDefaults.Teleprompter.readingGuide.read(from: preferences)
        countdownSeconds = min(10, max(0, SettingsDefaults.Teleprompter.countdown.read(from: preferences)))
        self.scriptText   = preferences.string(forKey: "teleprompter.script") ?? ""
        self.listeningMode = TeleprompterListeningMode(
            rawValue: SettingsDefaults.Teleprompter.listeningMode.read(from: preferences)
        ) ?? .classic
        let speed         = preferences.double(forKey: SettingsDefaults.Teleprompter.scrollSpeed.key)
        self.scrollSpeed  = speed > 0 ? speed : SettingsDefaults.Teleprompter.scrollSpeed.value
        let size          = preferences.double(forKey: SettingsDefaults.Teleprompter.fontSize.key)
        self.fontSize     = size > 0 ? size : SettingsDefaults.Teleprompter.fontSize.value
        let align         = preferences.object(forKey: SettingsDefaults.Teleprompter.alignment.key) as? Int
        self.textAlignmentIndex = align ?? SettingsDefaults.Teleprompter.alignment.value
        self.speechLocale = Self.defaultSpeechLocale(
            stored: preferences.string(forKey: SettingsDefaults.Teleprompter.speechLocaleKey)
        )
        self.speechRecognizer.onTerminalFailure = { [weak self] in
            guard let self, self.isPlaying else { return }
            self.pause()
            self.pendingCountdown = true
        }
        paragraphs = TeleprompterParagraph.parse(scriptText)
        pendingResumePosition = sessionStore.position(for: scriptText)
    }

    /// Restoring preferences pauses playback but never starts audio or requests access.
    func reloadRestoredPreferences() {
        isReloadingPreferences = true
        defer { isReloadingPreferences = false; updateGlobalShortcuts() }
        pause()
        listeningMode = TeleprompterListeningMode(rawValue: SettingsDefaults.Teleprompter.listeningMode.read(from: preferences)) ?? .classic
        scrollSpeed = SettingsDefaults.Teleprompter.scrollSpeed.read(from: preferences)
        fontSize = SettingsDefaults.Teleprompter.fontSize.read(from: preferences)
        textAlignmentIndex = SettingsDefaults.Teleprompter.alignment.read(from: preferences)
        speechLocale = Self.defaultSpeechLocale(stored: preferences.string(forKey: SettingsDefaults.Teleprompter.speechLocaleKey))
        columnWidth = SettingsDefaults.Teleprompter.columnWidth.read(from: preferences)
        showsReadingGuide = SettingsDefaults.Teleprompter.readingGuide.read(from: preferences)
        countdownSeconds = SettingsDefaults.Teleprompter.countdown.read(from: preferences)
        readingGuidePosition = SettingsDefaults.Teleprompter.guidePosition.read(from: preferences)
        globalShortcutsEnabled = SettingsDefaults.Teleprompter.globalShortcuts.read(from: preferences)
        shortcutModifiers = TeleprompterShortcutModifiers(rawValue: SettingsDefaults.Teleprompter.shortcutModifiers.read(from: preferences)) ?? .controlOption
    }

    // MARK: - Computed

    var hasScript: Bool {
        !scriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isCountingDown: Bool { countdownValue != nil }

    var wordTrackingDisplayText: String {
        TeleprompterTextTokenizer.displayText(from: scriptText)
    }

    // MARK: - Script

    func setScript(_ text: String) {
        scriptText = text
    }

    func resumeSavedPosition() {
        guard let position = pendingResumePosition else { return }
        pendingResumePosition = nil
        pause()
        classicProgress = position.progress
        classicParagraphOffset = position.displayOffset
        seekRequest = TeleprompterSeekRequest(displayOffset: position.displayOffset, progress: position.progress)
        speechRecognizer.preparePosition(in: scriptText, localeIdentifier: speechLocale, displayOffset: position.displayOffset)
        pendingCountdown = true
        recordReadingPosition(force: true)
    }

    func recordReadingPosition(force: Bool = false) {
        guard hasScript, pendingResumePosition == nil, force || Date().timeIntervalSince(lastPositionSave) >= 2 else { return }
        let offset = listeningMode == .wordTracking ? speechRecognizer.recognizedCharCount : classicParagraphOffset
        sessionStore.savePosition(TeleprompterReadingPosition(script: scriptText, displayOffset: offset, progress: readingProgress))
        lastPositionSave = Date()
    }

    func restartCurrentParagraph() {
        let offset = listeningMode == .wordTracking ? speechRecognizer.recognizedCharCount : classicParagraphOffset
        if let paragraph = paragraphs.last(where: { $0.id <= offset }) ?? paragraphs.first { jumpToParagraph(paragraph.id) }
    }

    func switchToClassicAtCurrentPosition() {
        guard listeningMode == .wordTracking else { return }
        let offset = speechRecognizer.recognizedCharCount
        listeningMode = .classic
        let paragraph = paragraphs.last(where: { $0.id <= offset }) ?? paragraphs.first
        if let paragraph { jumpToParagraph(paragraph.id) }
    }

    private func updateGlobalShortcuts() {
        guard !isReloadingPreferences else { return }
        globalShortcutConflict = !globalShortcuts.apply(enabled: isEnabled && globalShortcutsEnabled, modifiers: shortcutModifiers) { [weak self] action in
            guard let self, self.isEnabled, self.globalShortcutsEnabled else { return }
            if action == .playPause, self.pendingResumePosition == nil, self.listeningMode == .wordTracking, !self.isPlaying,
               (!PermissionsManager.shared.checkMicrophone() || !PermissionsManager.shared.checkSpeechRecognition()) { return }
            self.perform(action)
        }
    }

    // MARK: - Playback

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        updateGlobalShortcuts()
        if !enabled {
            pause()
            pendingCountdown = true
        }
    }

    func play() {
        guard isEnabled, presentationState.teleprompterEnabled, hasScript, !isPlaying, !isCountingDown else { return }
        if pendingResumePosition != nil {
            presentationState.presentFullExpandedModule(.teleprompter)
            return
        }
        presentTeleprompter()
        if pendingCountdown {
            pendingCountdown = false
            startCountdown()
        } else {
            beginPlayback()
        }
    }

    func pause() {
        recordReadingPosition(force: true)
        captureClassicViewPosition()
        if isCountingDown { pendingCountdown = true }
        cancelCountdown()
        isPlaying = false
        speechRecognizer.stop()
        releaseTeleprompterPresentation()
    }

    func reset() {
        pendingResumePosition = nil
        sessionStore.clearPosition()
        cancelCountdown()
        isPlaying = false
        pendingCountdown = true
        scrollNudge = 0
        classicProgress = 0
        classicParagraphOffset = 0
        seekRequest = TeleprompterSeekRequest(displayOffset: 0)
        resetToken = UUID()
        speechRecognizer.reset()
        releaseTeleprompterPresentation()
    }

    func togglePlayPause() {
        if isPlaying || isCountingDown { pause() } else { play() }
    }

    /// Seek the scroll position by `delta` pixels. Positive = forward (toward end).
    /// Additive to ongoing auto-scroll — does NOT pause playback.
    func nudgeOffset(by delta: CGFloat) {
        guard isEnabled, hasScript else { return }
        scrollNudge += delta
    }

    func reportProgress(_ fraction: Double, paragraphOffset: Int? = nil) {
        guard fraction.isFinite, pendingResumePosition == nil else { return }
        if let paragraphOffset, paragraphs.contains(where: { $0.id == paragraphOffset }) {
            classicParagraphOffset = paragraphOffset
        }
        let next = min(1, max(0, fraction))
        if abs(next - classicProgress) >= 0.005 || next == 0 || next == 1 { classicProgress = next }
        recordReadingPosition()
    }

    func jumpToParagraph(_ offset: Int) {
        guard isEnabled, let paragraph = paragraphs.first(where: { $0.id == offset }) else { return }
        pause()
        pendingCountdown = true
        seekRequest = TeleprompterSeekRequest(displayOffset: paragraph.id)
        classicParagraphOffset = paragraph.id
        classicProgress = Double(paragraph.id) / Double(max(1, wordTrackingDisplayText.count))
        speechRecognizer.preparePosition(in: scriptText, localeIdentifier: speechLocale, displayOffset: paragraph.id)
        recordReadingPosition(force: true)
    }

    func captureClassicViewPosition() {
        guard listeningMode == .classic, pendingResumePosition == nil else { return }
        seekRequest = TeleprompterSeekRequest(displayOffset: classicParagraphOffset, progress: classicProgress)
    }

    func perform(_ action: TeleprompterKeyboardAction) {
        guard isEnabled else { return }
        switch action {
        case .playPause: togglePlayPause()
        case .pause: pause()
        case .faster: scrollSpeed = min(30, scrollSpeed + 1)
        case .slower: scrollSpeed = max(1, scrollSpeed - 1)
        case .nextParagraph, .previousParagraph:
            guard !paragraphs.isEmpty else { return }
            let current = listeningMode == .classic ? classicParagraphOffset : speechRecognizer.recognizedCharCount
            let index = paragraphs.lastIndex(where: { $0.id <= current }) ?? 0
            let target = min(paragraphs.count - 1, max(0, index + (action == .nextParagraph ? 1 : -1)))
            jumpToParagraph(paragraphs[target].id)
        }
    }

    // MARK: - Countdown

    private func startCountdown() {
        cancelCountdown()
        let generation = countdownGeneration
        var remaining = min(10, max(0, countdownSeconds))
        guard remaining > 0 else { beginPlayback(); return }
        countdownValue = remaining
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled, self.countdownGeneration == generation else { return }
                remaining -= 1
                if remaining > 0 {
                    self.countdownValue = remaining
                } else {
                    self.cancelCountdown()
                    self.beginPlayback()
                }
            }
        }
        countdownTimer?.tolerance = 0.1
    }

    private func beginPlayback() {
        guard isEnabled, presentationState.teleprompterEnabled else { return }
        if listeningMode == .wordTracking {
            speechRecognizer.start(with: scriptText, localeIdentifier: speechLocale, resuming: true)
            if speechRecognizer.error != nil, !speechRecognizer.isListening {
                isPlaying = false
                pendingCountdown = true
                releaseTeleprompterPresentation()
                return
            }
        }
        isPlaying = true
    }

    private func cancelCountdown() {
        countdownGeneration = UUID()
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownValue = nil
    }

    private func presentTeleprompter() {
        let appState = presentationState
        guard appState.teleprompterEnabled else { return }
        let module = ActiveModule.builtIn(.teleprompter)
        appState.holdPresentation(for: module)
        if appState.currentState == .fullExpanded {
            appState.selectFullExpandedTab(.module(module))
            appState.cancelFullExpandedDismiss()
        } else {
            appState.showHUD(module: module, autoDismiss: false)
            appState.cancelAutoDismiss()
        }
    }

    private func releaseTeleprompterPresentation() {
        presentationState.releasePresentationHold(for: .builtIn(.teleprompter))
    }

    private static func defaultSpeechLocale(stored: String?) -> String {
        let supported = Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        let candidates = [stored].compactMap { $0 }
            + [Locale.current.identifier]
            + Locale.preferredLanguages
            + ["zh-CN", "en-US"]

        for candidate in candidates {
            if supported.contains(candidate) { return candidate }

            let normalized = candidate.replacingOccurrences(of: "_", with: "-")
            if supported.contains(normalized) { return normalized }

            if normalized.hasPrefix("zh-Hans") || normalized.hasPrefix("zh-CN") {
                if supported.contains("zh-CN") { return "zh-CN" }
            }
            if normalized.hasPrefix("zh-Hant") || normalized.hasPrefix("zh-TW") {
                if supported.contains("zh-TW") { return "zh-TW" }
            }
            if normalized.hasPrefix("zh-HK") {
                if supported.contains("zh-HK") { return "zh-HK" }
            }
            if normalized.hasPrefix("en") {
                if supported.contains("en-US") { return "en-US" }
            }
        }

        return supported.sorted().first ?? "en-US"
    }
}
