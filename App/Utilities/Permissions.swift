import AppKit
import Carbon
import AVFoundation
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import Speech
import UserNotifications
import Combine

struct PermissionSnapshot: Equatable {
    var granted: Set<PermissionType> = []
    var microphone = AVAuthorizationStatus.notDetermined
    var speech = SFSpeechRecognizerAuthorizationStatus.notDetermined
    var notifications = UNAuthorizationStatus.notDetermined
}

/// Shared consent snapshot; no polling, sampling or automatic permission requests.
@MainActor
final class PermissionState: ObservableObject {
    static let shared = PermissionState()
    @Published private(set) var snapshot: PermissionSnapshot?
    @Published private(set) var requesting: Set<PermissionType> = []
    private let read: () async -> PermissionSnapshot
    private let requestSystem: (PermissionType) async -> Void
    private var revision = UUID()

    init(read: @escaping () async -> PermissionSnapshot = { await PermissionState.readSystem() },
         request: @escaping (PermissionType) async -> Void = { await PermissionState.requestSystem($0) }) {
        self.read = read
        self.requestSystem = request
    }

    func refresh() async {
        let id = UUID()
        revision = id
        let value = await read()
        guard revision == id else { return }
        snapshot = value
    }

    func request(_ permission: PermissionType) async {
        guard requesting.insert(permission).inserted else { return }
        defer { requesting.remove(permission) }
        await requestSystem(permission)
        await refresh()
    }

    func requestWordTrackingAccess() async {
        await withCheckedContinuation { continuation in
            PermissionsManager.shared.requestTeleprompterWordTrackingAccess { _ in continuation.resume() }
        }
        await refresh()
    }

    private static func readSystem() async -> PermissionSnapshot {
        let manager = PermissionsManager.shared
        var result = PermissionSnapshot()
        for permission in PermissionType.allCases where permission != .notifications {
            if manager.check(permission) == true { result.granted.insert(permission) }
        }
        result.microphone = manager.microphoneAuthorizationStatus()
        result.speech = manager.speechRecognitionAuthorizationStatus()
        result.notifications = await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { continuation.resume(returning: $0.authorizationStatus) }
        }
        switch result.notifications {
        case .authorized, .provisional, .ephemeral: result.granted.insert(.notifications)
        default: break
        }
        return result
    }

    private static func requestSystem(_ permission: PermissionType) async {
        let manager = PermissionsManager.shared
        switch permission {
        case .calendar: _ = await manager.requestCalendarAccess()
        case .notifications: _ = await manager.requestNotificationAccess()
        case .microphone:
            await withCheckedContinuation { continuation in
                manager.requestMicrophoneAccess { _ in continuation.resume() }
            }
        case .speechRecognition:
            await withCheckedContinuation { continuation in
                manager.requestSpeechRecognitionAccess { _ in continuation.resume() }
            }
        default: manager.request(permission)
        }
    }
}

enum PermissionType: CaseIterable {
    case accessibility
    case screenRecording
    case calendar
    case notifications
    case microphone
    case speechRecognition
    case location
    case bluetooth

    var title: String {
        switch self {
        case .accessibility: return L10n.text("Accessibility")
        case .screenRecording: return L10n.text("Screen Recording")
        case .calendar: return L10n.text("Calendar")
        case .notifications: return L10n.text("Notifications")
        case .microphone: return L10n.text("Microphone")
        case .speechRecognition: return L10n.text("Speech Recognition")
        case .location: return L10n.text("Location")
        case .bluetooth: return L10n.text("Bluetooth")
        }
    }

    var description: String {
        switch self {
        case .accessibility: return L10n.text("Needed for gesture detection and system event monitoring")
        case .screenRecording: return L10n.text("Lets NotchX appear properly in screen recordings")
        case .calendar: return L10n.text("Show upcoming events in NotchX")
        case .notifications: return L10n.text("Show supported notification sources in NotchX")
        case .microphone: return L10n.text("Audio visualization for the spectrogram")
        case .speechRecognition: return L10n.text("Follow along with Teleprompter scripts as you read")
        case .location: return L10n.text("Provide weather information for your location")
        case .bluetooth: return L10n.text("Show connected device notifications")
        }
    }

    var iconName: String {
        switch self {
        case .accessibility: return "figure.stand"
        case .screenRecording: return "display"
        case .calendar: return "calendar"
        case .notifications: return "bell.badge.fill"
        case .microphone: return "mic.fill"
        case .speechRecognition: return "text.word.spacing"
        case .location: return "location.fill"
        case .bluetooth: return "wave.3.right.circle.fill"
        }
    }

    var isRequired: Bool {
        switch self {
        case .accessibility, .screenRecording:
            return true
        case .calendar, .notifications, .microphone, .speechRecognition, .location, .bluetooth:
            return false
        }
    }
}

private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}

final class PermissionsManager {
    static let shared = PermissionsManager()
    private static let accessibilityPromptedDefaultsKey = "permissions.accessibilityPrompted"
    private var locationManager: CLLocationManager?
    private let locationDelegate = LocationDelegate()
    private var calendarStore: EKEventStore?
    private var bluetoothTrigger: CBCentralManager?

    private init() {}

    /// Checks Apple Events consent without presenting a TCC prompt. Automatic
    /// media polling must call this before executing scripts against an app.
    static func hasAutomationAccess(to bundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, false
        ) == noErr
    }

    /// Explicit settings/user action only.
    static func requestAutomationAccess(to bundleIdentifier: String) -> Bool {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier)
        return AEDeterminePermissionToAutomateTarget(
            target.aeDesc, typeWildCard, typeWildCard, true
        ) == noErr
    }

    // MARK: - Unified API

    func check(_ permission: PermissionType) -> Bool? {
        switch permission {
        case .accessibility:
            return checkAccessibility()
        case .screenRecording:
            return checkScreenRecording()
        case .calendar:
            return checkCalendar()
        case .notifications:
            // Unknown is not denied. Use the shared async snapshot for notifications.
            return nil
        case .microphone:
            return checkMicrophone()
        case .speechRecognition:
            return checkSpeechRecognition()
        case .location:
            return checkLocation()
        case .bluetooth:
            return checkBluetooth()
        }
    }

    func request(_ permission: PermissionType) {
        switch permission {
        case .accessibility:
            requestAccessibility()
        case .screenRecording:
            _ = requestScreenRecordingAccess()
        case .calendar:
            Task { @MainActor in _ = await requestCalendarAccess() }
        case .notifications:
            Task { _ = await requestNotificationAccess() }
        case .microphone:
            requestMicrophoneAccess()
        case .speechRecognition:
            requestSpeechRecognitionAccess()
        case .location:
            requestLocationAccess()
        case .bluetooth:
            Task { @MainActor in openBluetoothSettings() }
        }
    }

    // MARK: - Accessibility

    func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func requestAccessibility() {
        guard !AXIsProcessTrusted() else { return }
        UserDefaults.standard.set(true, forKey: Self.accessibilityPromptedDefaultsKey)
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Screen Recording

    func checkScreenRecording() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    // MARK: - Calendar

    func checkCalendar() -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        switch status {
        case .fullAccess:
            return true
        default:
            return false
        }
    }

    @MainActor func requestCalendarAccess() async -> Bool {
        if calendarStore == nil { calendarStore = EKEventStore() }

        await MainActor.run { NSApp.activate(ignoringOtherApps: true) }

        // Call unconditionally — the API handles all states internally:
        // .notDetermined  → shows TCC dialog
        // .fullAccess     → returns true immediately (already granted)
        // .denied         → throws (caught by try?, falls through to Settings)
        // On macOS 15 the default pre-request status may not be .notDetermined,
        // so checking status first would skip the dialog entirely.
        if let granted = try? await calendarStore!.requestFullAccessToEvents(), granted {
            return true
        }

        // Open System Settings so the user can grant Full Access manually.
        await MainActor.run { openCalendarSettings() }
        return false
    }

    // MARK: - Notifications

    func notificationsGranted() async -> Bool {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    continuation.resume(returning: true)
                case .notDetermined, .denied:
                    continuation.resume(returning: false)
                @unknown default:
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func requestNotificationAccess() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    // MARK: - Microphone

    func checkMicrophone() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func microphoneAuthorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestMicrophoneAccess(completion: ((Bool) -> Void)? = nil) {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .authorized {
            completion?(true)
            return
        }
        if status == .denied || status == .restricted {
            openMicrophoneSettings()
            completion?(false)
            return
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    completion?(granted)
                }
            }
        }
    }

    // MARK: - Speech Recognition

    func checkSpeechRecognition() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    func speechRecognitionAuthorizationStatus() -> SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    func requestSpeechRecognitionAccess(completion: ((Bool) -> Void)? = nil) {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized {
            completion?(true)
            return
        }
        if status == .denied || status == .restricted {
            openSpeechRecognitionSettings()
            completion?(false)
            return
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            SFSpeechRecognizer.requestAuthorization { status in
                DispatchQueue.main.async {
                    completion?(status == .authorized)
                }
            }
        }
    }

    func requestTeleprompterWordTrackingAccess(completion: ((Bool) -> Void)? = nil) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)

            let requestGroup = DispatchGroup()
            var microphoneGranted = self.checkMicrophone()
            var speechGranted = self.checkSpeechRecognition()

            requestGroup.enter()
            self.requestMicrophoneAccess { granted in
                microphoneGranted = granted
                requestGroup.leave()
            }

            requestGroup.enter()
            self.requestSpeechRecognitionAccess { granted in
                speechGranted = granted
                requestGroup.leave()
            }

            requestGroup.notify(queue: .main) {
                completion?(microphoneGranted && speechGranted)
                Task { @MainActor in await PermissionState.shared.refresh() }
            }
        }
    }

    // MARK: - Location

    func checkLocation() -> Bool {
        ensureLocationManager()
        return isAuthorizedLocationStatus(locationManager!.authorizationStatus)
    }

    func requestLocationAccess() {
        ensureLocationManager()
        let status = locationManager!.authorizationStatus
        guard !isAuthorizedLocationStatus(status) else { return }

        if status == .denied || status == .restricted {
            openLocationSettings()
            return
        }

        // .notDetermined — request authorization, then open Settings as fallback
        NSApp.activate(ignoringOtherApps: true)
        locationManager?.requestAlwaysAuthorization()

        // If the system dialog doesn't appear (LSUIElement quirk), open Settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, let mgr = self.locationManager else { return }
            if mgr.authorizationStatus == .notDetermined {
                self.openLocationSettings()
            }
        }
    }

    private func ensureLocationManager() {
        guard locationManager == nil else { return }
        locationManager = CLLocationManager()
        locationManager?.delegate = locationDelegate
        // This service checks consent only. Weather owns location sampling;
        // browsing permissions must not create an unconsumed location request.
        locationDelegate.onAuthorizationChange = { _ in
            Task { @MainActor in await PermissionState.shared.refresh() }
        }
    }

    private func isAuthorizedLocationStatus(_ status: CLAuthorizationStatus) -> Bool {
        switch status {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    // MARK: - Bluetooth

    func checkBluetooth() -> Bool {
        let auth = CBManager.authorization
        return auth == .allowedAlways
    }

    // MARK: - Open System Settings

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    func openCalendarSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    func openNotificationsSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
        NSWorkspace.shared.open(url)
    }

    func openMicrophoneSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        NSWorkspace.shared.open(url)
    }

    func openSpeechRecognitionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
        NSWorkspace.shared.open(url)
    }

    func openLocationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!
        NSWorkspace.shared.open(url)
    }

    @MainActor func openBluetoothSettings(fromIsland appState: AppState? = nil) {
        let handoff = appState?.beginPresentationHandoff(.external, for: .connectivity)
        if appState != nil, handoff == nil { return }
        // Creating a CBCentralManager triggers the system Bluetooth permission prompt,
        // which registers NotchX in the Bluetooth privacy list.
        if bluetoothTrigger == nil {
            bluetoothTrigger = CBCentralManager()
        }
        // Give the system a moment to register the app, then open Settings
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let handoff, appState?.isPresentationHandoffActive(handoff) != true { return }
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
            let opened = NSWorkspace.shared.open(url)
            if let handoff { appState?.finishPresentationHandoff(handoff, outcome: opened ? .completed : .failed) }
        }
    }
}
