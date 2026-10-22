import AppKit
import Combine

enum KeyboardCleaningState: Equatable {
    case idle, locked, releasing
    var isBlocking: Bool { self != .idle }
}

enum KeepAwakeDuration: Int, CaseIterable, Identifiable {
    case fifteenMinutes = 900, thirtyMinutes = 1800, sixtyMinutes = 3600
    case twoHours = 7200, custom = -1, forever = 0
    var id: Int { rawValue }
    static func boundedCustomMinutes(_ value: Double) -> Double {
        value.isFinite ? min(1440, max(1, value.rounded())) : 90
    }
    func seconds(customMinutes: Double) -> TimeInterval? {
        switch self {
        case .forever: return nil
        case .custom:
            return Self.boundedCustomMinutes(customMinutes) * 60
        default: return TimeInterval(rawValue)
        }
    }
    var title: String {
        switch self {
        case .custom: return L10n.text("Custom")
        case .forever: return L10n.text("Forever")
        case .sixtyMinutes: return L10n.text("1 hour")
        case .twoHours: return L10n.text("2 hours")
        default: return L10n.format("%d min", rawValue / 60)
        }
    }
}

@MainActor
final class ToolsManager: ObservableObject {
    static let shared = ToolsManager()

    @Published private(set) var isKeepingAwake = false
    @Published private(set) var cleaningState = KeyboardCleaningState.idle
    @Published private(set) var awakeError: String?
    @Published private(set) var cleaningError: String?
    private(set) var isEnabled = false
    private var awakeDeadline: TimeInterval?
    private var awakeExpiry: DispatchWorkItem?
    private let assertion: KeepAwakeAsserting
    private let keyboard: KeyboardInputBlocking
    private let uptime: () -> TimeInterval
    private let appState: @MainActor () -> AppState
    private let monitorsSystem: Bool
    private var healthTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var cleaningGeneration = UUID()

    init(assertion: KeepAwakeAsserting? = nil, keyboard: KeyboardInputBlocking? = nil,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         appState: @escaping @MainActor () -> AppState = { .shared }, monitorsSystem: Bool = true) {
        self.assertion = assertion ?? KeepAwakeAssertion()
        self.keyboard = keyboard ?? KeyboardInputBlocker()
        self.uptime = uptime
        self.appState = appState
        self.monitorsSystem = monitorsSystem
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        guard isEnabled != enabled else { return true }
        if !enabled {
            stopKeepingAwake()
            finishCleaning()
            stopObservingSystem()
            // Keep the module and its error/retry controls reachable when the
            // system refuses to release an assertion. Never invent shutdown.
            guard !isKeepingAwake else { return false }
        }
        objectWillChange.send()
        isEnabled = enabled
        return true
    }

    var hasKeyboardAccess: Bool { keyboard.hasAccessibility }
    var awakeRemaining: TimeInterval { awakeDeadline.map { max(0, $0 - uptime()) } ?? 0 }
    var isAwakeIndefinite: Bool { isKeepingAwake && awakeDeadline == nil }
    var awakeRemainingDescription: String {
        if isAwakeIndefinite { return L10n.text("Until turned off") }
        if awakeRemaining >= 3600 {
            let minutes = Int(ceil(awakeRemaining / 60))
            return L10n.format("%dh %dm remaining", minutes / 60, minutes % 60)
        }
        return L10n.format("%@ remaining", Self.countdownText(awakeRemaining))
    }

    static func countdownText(_ remaining: TimeInterval) -> String {
        let remaining = min(86_400, max(0, remaining))
        if remaining >= 3600 {
            let minutes = Int(ceil(remaining / 60))
            return String(format: "%d:%02d", minutes / 60, minutes % 60)
        }
        let seconds = Int(ceil(remaining))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    func startKeepingAwake(for duration: KeepAwakeDuration) {
        guard isEnabled, !isKeepingAwake else { return }
        guard assertion.acquire() else {
            awakeError = L10n.text("Could not enable Keep Awake. Try again.")
            return
        }
        awakeError = nil
        awakeDeadline = duration.seconds(customMinutes: appState().keepAwakeCustomMinutes).map { uptime() + $0 }
        isKeepingAwake = true
        appState().setKeepAwakeActive(true)
        scheduleAwakeExpiry()
    }

    func stopKeepingAwake() {
        guard assertion.release() else {
            awakeError = L10n.text("Could not turn off Keep Awake. Try again.")
            return
        }
        awakeError = nil
        awakeExpiry?.cancel()
        awakeExpiry = nil
        awakeDeadline = nil
        isKeepingAwake = false
        appState().setKeepAwakeActive(false)
    }

    func checkAwakeExpiry() {
        guard isKeepingAwake, awakeDeadline != nil else { return }
        if awakeRemaining <= 0 { stopKeepingAwake() }
        if isKeepingAwake { scheduleAwakeExpiry() }
    }

    private func scheduleAwakeExpiry() {
        awakeExpiry?.cancel()
        guard monitorsSystem, awakeDeadline != nil else { return }
        let item = DispatchWorkItem { [weak self] in self?.checkAwakeExpiry() }
        awakeExpiry = item
        DispatchQueue.main.asyncAfter(deadline: .now() + max(1, awakeRemaining), execute: item)
    }

    func startCleaning() {
        guard isEnabled, !cleaningState.isBlocking else { return }
        guard keyboard.hasAccessibility else {
            cleaningError = L10n.text("Allow Accessibility access, then click Start Cleaning again.")
            return
        }
        guard !keyboard.hasPressedKeys else {
            cleaningError = L10n.text("Release all keys, then click Start Cleaning again.")
            return
        }
        let generation = UUID()
        cleaningGeneration = generation
        guard keyboard.start(onInterruption: { [weak self] in
            guard let self, self.cleaningGeneration == generation else { return }
            self.interruptCleaning()
        }) else {
            cleaningError = L10n.text("Could not lock the keyboard. Cleaning has not started.")
            return
        }
        cleaningError = nil
        cleaningState = .locked
        appState().setKeyboardCleaningActive(true)
        observeSystemIfNeeded()
        if monitorsSystem {
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkCleaningHealth() }
            }
            healthTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Only the mouse-operated End Cleaning button calls this; no key can unlock.
    func endCleaning() {
        guard cleaningState.isBlocking else { return }
        // Swallow final key-up events before restoring delivery to other apps.
        if keyboard.hasPressedKeys { cleaningState = .releasing }
        else { finishCleaning() }
    }

    func checkCleaningHealth() {
        guard cleaningState.isBlocking else { return }
        guard keyboard.isHealthy else { interruptCleaning(); return }
        if cleaningState == .releasing, !keyboard.hasPressedKeys { finishCleaning() }
    }

    func interruptCleaning() {
        guard cleaningState.isBlocking else { return }
        finishCleaning()
        cleaningError = L10n.text("Cleaning interrupted. The keyboard is no longer locked.")
        if isEnabled { appState().presentFullExpandedModule(.tools) }
    }

    private func finishCleaning() {
        cleaningGeneration = UUID()
        healthTimer?.invalidate()
        healthTimer = nil
        keyboard.stop()
        cleaningState = .idle
        appState().setKeyboardCleaningActive(false)
        stopObservingSystem()
    }

    private func observeSystemIfNeeded() {
        guard monitorsSystem, observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.screensDidSleepNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.interruptCleaning() }
            })
        }
    }

    private func stopObservingSystem() {
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
}
