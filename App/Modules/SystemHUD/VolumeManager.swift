import Foundation
import CoreAudio
import AudioToolbox
import Combine
import AppKit

struct MediaAppVolume: Identifiable, Equatable {
    let id: String
    let appName: String
    let bundleIdentifier: String
    let iconName: String
    var volume: Float
    var isPlaying: Bool

    var statusText: String {
        isPlaying ? L10n.text("Playing") : L10n.text("Paused")
    }
}

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let icon: String
}

private final class VolumeWorkSession: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

@MainActor
final class VolumeManager: ObservableObject {
    static let shared = VolumeManager()
    var onVolumeChanged: (() -> Void)?

    @Published var volume: Float = 0
    @Published var isMuted: Bool = false
    @Published var outputDeviceName: String = "Unknown"
    @Published var mediaAppVolumes: [MediaAppVolume] = []
    @Published private(set) var canSetVolume = false
    @Published private(set) var canMute = false
    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    var selectedOutputDeviceID: AudioDeviceID { defaultDeviceID }
    @Published private(set) var controlError: String?

    private var isEnabled = false
    private var lifecycleGeneration = UUID()
    private var mediaWorkSession = VolumeWorkSession()
    private var defaultDeviceID: AudioDeviceID = 0
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var mediaRefreshToken: ModuleRefreshToken?
    private var mediaRefreshID: UUID?
    private let appleScriptQueue = DispatchQueue(label: "app.notchx.applescript", qos: .utility)

    private init() {}

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        lifecycleGeneration = UUID()
        mediaWorkSession.cancel()
        mediaWorkSession = VolumeWorkSession()
        if enabled {
            setupDefaultDevice()
            updateVolume()
            updateMuteState()
            updateDeviceName()
            startMonitoring()
            startMediaMonitoring()
        } else {
            onVolumeChanged = nil
            mediaRefreshID = nil
            mediaAppVolumes = []
            stopMonitoring()
            ModuleRefreshScheduler.shared.unregister(mediaRefreshToken)
            mediaRefreshToken = nil
        }
    }

    private func stopMonitoring() {
        var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var deviceAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        if let block = volumeListenerBlock { AudioObjectRemovePropertyListenerBlock(defaultDeviceID, &volumeAddress, DispatchQueue.main, block) }
        if let block = muteListenerBlock { AudioObjectRemovePropertyListenerBlock(defaultDeviceID, &muteAddress, DispatchQueue.main, block) }
        if let block = deviceListenerBlock { AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &deviceAddress, DispatchQueue.main, block) }
        volumeListenerBlock = nil
        muteListenerBlock = nil
        deviceListenerBlock = nil
    }

    // MARK: - Setup

    private func setupDefaultDevice() {
        defaultDeviceID = 0
        volume = 0
        isMuted = false
        outputDeviceName = L10n.text("Unknown")
        canSetVolume = false
        canMute = false
        controlError = nil
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )

        if status == noErr {
            defaultDeviceID = deviceID
            var volumeAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var settable: DarwinBoolean = false
            canSetVolume = AudioObjectIsPropertySettable(deviceID, &volumeAddress, &settable) == noErr && settable.boolValue
            var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            canMute = AudioObjectIsPropertySettable(deviceID, &muteAddress, &settable) == noErr && settable.boolValue
        }
        refreshOutputDevices()
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        let generation = lifecycleGeneration
        // Listen for volume changes
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let volumeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
                self.updateVolume()
                self.onVolumeChanged?()
            }
        }
        volumeListenerBlock = volumeBlock

        AudioObjectAddPropertyListenerBlock(
            defaultDeviceID, &volumeAddress,
            DispatchQueue.main, volumeBlock
        )

        // Listen for mute changes
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
                self.updateMuteState()
                self.onVolumeChanged?()
            }
        }
        muteListenerBlock = muteBlock

        AudioObjectAddPropertyListenerBlock(
            defaultDeviceID, &muteAddress,
            DispatchQueue.main, muteBlock
        )

        // Listen for default device changes
        var deviceAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async {
                guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
                self.stopMonitoring()
                self.lifecycleGeneration = UUID()
                self.mediaRefreshID = nil
                self.setupDefaultDevice()
                self.updateVolume()
                self.updateMuteState()
                self.updateDeviceName()
                self.startMonitoring()
            }
        }
        deviceListenerBlock = deviceBlock

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            DispatchQueue.main, deviceBlock
        )
    }

    private func startMediaMonitoring() {
        mediaRefreshToken = ModuleRefreshScheduler.shared.register(
            id: "volume.mediaApps",
            name: "Media app volume refresh",
            module: .builtIn(.volumeHUD),
            policy: .visibleOnly(8, tolerance: 2),
            enabled: { [weak self] in self?.isEnabled == true }
        ) { [weak self] in
            self?.refreshMediaAppVolumes()
        }
    }

    // MARK: - State Updates

    private func updateVolume() {
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            defaultDeviceID, &address, 0, nil, &size, &vol
        )

        if status == noErr, vol.isFinite {
            volume = max(0, min(1, vol))
        }
    }

    private func updateMuteState() {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            defaultDeviceID, &address, 0, nil, &size, &muted
        )

        if status == noErr {
            isMuted = muted != 0
        }
    }

    private func updateDeviceName() {
        // Core Audio writes a retained CFStringRef into an untyped output buffer.
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            defaultDeviceID, &address, 0, nil, &size, &name
        )

        if status == noErr, let name {
            outputDeviceName = name.takeRetainedValue() as String
        }
    }

    // MARK: - Volume Control

    func refreshOutputDevices() {
        guard isEnabled else { return }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { outputDevices = []; return }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }
        guard status == noErr else { outputDevices = []; return }
        outputDevices = ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceNameCFString, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr, let name else { return nil }
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            _ = AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
            let icon: String
            switch transport {
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: icon = "headphones"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: icon = "display"
            case kAudioDeviceTransportTypeAirPlay: icon = "airplayaudio"
            default: icon = "speaker.wave.2"
            }
            return AudioOutputDevice(id: id, name: name.takeRetainedValue() as String, icon: icon)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func selectOutputDevice(_ id: AudioDeviceID) {
        guard isEnabled, outputDevices.contains(where: { $0.id == id }) else { return }
        var target = id
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &target)
        guard status == noErr else { controlError = L10n.text("Output device change failed."); return }
        stopMonitoring()
        lifecycleGeneration = UUID()
        mediaRefreshID = nil
        setupDefaultDevice()
        updateVolume()
        updateMuteState()
        updateDeviceName()
        startMonitoring()
    }

    func setVolume(_ newVolume: Float) {
        guard isEnabled, canSetVolume, newVolume.isFinite else { return }
        var vol = max(0, min(1, newVolume))
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            defaultDeviceID, &address, 0, nil, size, &vol
        )
        controlError = status == noErr ? nil : L10n.text("Volume change failed.")
        updateVolume()
    }

    func toggleMute() {
        guard isEnabled, canMute else { return }
        var muted: UInt32 = isMuted ? 0 : 1
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            defaultDeviceID, &address, 0, nil, size, &muted
        )
        controlError = status == noErr ? nil : L10n.text("Mute change failed.")
        updateMuteState()
    }

    // MARK: - Media App Volume

    func refreshMediaAppVolumes() {
        guard isEnabled, mediaRefreshID == nil else { return }
        let refreshID = UUID()
        mediaRefreshID = refreshID
        let generation = lifecycleGeneration
        let session = mediaWorkSession
        appleScriptQueue.async { [weak self] in
            guard let self, session.isActive else { return }
            var apps: [MediaAppVolume] = []
            if let spotify = self.fetchMusicAppVolume(
                appID: "spotify",
                appName: "Spotify",
                bundleIdentifier: "com.spotify.client",
                processName: "Spotify",
                scriptAppName: "Spotify",
                iconName: "music.note.list",
                session: session
            ) {
                apps.append(spotify)
            }
            if let music = self.fetchMusicAppVolume(
                appID: "apple-music",
                appName: "Apple Music",
                bundleIdentifier: "com.apple.Music",
                processName: "Music",
                scriptAppName: "Music",
                iconName: "music.note",
                session: session
            ) {
                apps.append(music)
            }
            if let chrome = self.fetchChromeMediaVolume(session: session) {
                apps.append(chrome)
            }

            let sorted = apps.sorted { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying {
                    return lhs.isPlaying && !rhs.isPlaying
                }
                return lhs.appName < rhs.appName
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
                guard self.mediaRefreshID == refreshID else { return }
                self.mediaRefreshID = nil
                self.mediaAppVolumes = sorted
            }
        }
    }

    func setMediaAppVolume(appID: String, volume: Float) {
        guard isEnabled, volume.isFinite else { return }
        let clamped = max(0, min(1, volume))

        if let index = mediaAppVolumes.firstIndex(where: { $0.id == appID }) {
            mediaAppVolumes[index].volume = clamped
        }

        switch appID {
        case "spotify":
            setMusicAppVolume(
                bundleIdentifier: "com.spotify.client",
                processName: "Spotify",
                scriptAppName: "Spotify",
                volume: clamped
            )
        case "apple-music":
            setMusicAppVolume(
                bundleIdentifier: "com.apple.Music",
                processName: "Music",
                scriptAppName: "Music",
                volume: clamped
            )
        case "chrome":
            setChromeMediaVolume(clamped)
        default:
            break
        }
    }

    nonisolated private func fetchMusicAppVolume(
        appID: String,
        appName: String,
        bundleIdentifier: String,
        processName: String,
        scriptAppName: String,
        iconName: String,
        session: VolumeWorkSession
    ) -> MediaAppVolume? {
        guard PermissionsManager.hasAutomationAccess(to: bundleIdentifier),
              PermissionsManager.hasAutomationAccess(to: "com.apple.systemevents"),
              isApplicationInstalled(bundleIdentifier: bundleIdentifier),
              isApplicationRunning(bundleIdentifier: bundleIdentifier, processName: processName) else {
            return nil
        }

        let script = """
        tell application "System Events"
            if not (exists process "\(processName)") then return "NOT_RUNNING"
        end tell
        tell application "\(scriptAppName)"
            set stateText to (player state as string)
            set vol to sound volume
            return (vol as string) & "||" & stateText
        end tell
        """

        guard session.isActive, let result = runAppleScript(script), result != "NOT_RUNNING" else { return nil }
        let parts = result.components(separatedBy: "||")
        guard parts.count >= 2 else { return nil }

        let volumeValue = (Float(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 100.0
        let state = parts[1].lowercased()
        let isPlaying = state.contains("play")

        return MediaAppVolume(
            id: appID,
            appName: appName,
            bundleIdentifier: bundleIdentifier,
            iconName: iconName,
            volume: max(0, min(1, volumeValue)),
            isPlaying: isPlaying
        )
    }

    private func setMusicAppVolume(bundleIdentifier: String, processName: String, scriptAppName: String, volume: Float) {
        guard PermissionsManager.hasAutomationAccess(to: bundleIdentifier),
              PermissionsManager.hasAutomationAccess(to: "com.apple.systemevents"),
              isApplicationInstalled(bundleIdentifier: bundleIdentifier),
              isApplicationRunning(bundleIdentifier: bundleIdentifier, processName: processName) else {
            return
        }

        let target = Int((max(0, min(1, volume)) * 100).rounded())
        let script = """
        tell application "System Events"
            if not (exists process "\(processName)") then return
        end tell
        tell application "\(scriptAppName)"
            set sound volume to \(target)
        end tell
        """
        let session = mediaWorkSession
        appleScriptQueue.async { [weak self] in
            guard session.isActive else { return }
            _ = self?.runAppleScript(script)
        }
    }

    nonisolated private func fetchChromeMediaVolume(session: VolumeWorkSession) -> MediaAppVolume? {
        guard PermissionsManager.hasAutomationAccess(to: "com.google.Chrome"),
              PermissionsManager.hasAutomationAccess(to: "com.apple.systemevents"),
              isApplicationInstalled(bundleIdentifier: "com.google.Chrome"),
              isApplicationRunning(bundleIdentifier: "com.google.Chrome", processName: "Google Chrome") else {
            return nil
        }

        let script = """
        tell application "System Events"
            if not (exists process "Google Chrome") then return "NOT_RUNNING"
        end tell
        tell application "Google Chrome"
            set foundMedia to false
            set maxVolume to 0
            set hasPlaying to false
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set mediaInfo to execute t javascript "(function(){var media=document.querySelectorAll('video,audio');if(!media.length){return 'NO_MEDIA';}var playing=false;var highest=0;for(var i=0;i<media.length;i++){var m=media[i];if(!m.paused&&!m.ended){playing=true;}var v=m.muted?0:m.volume;if(v>highest){highest=v;}}return (playing?'PLAYING':'PAUSED')+'||'+highest;})();"
                        if mediaInfo is not "NO_MEDIA" then
                            set foundMedia to true
                            set AppleScript's text item delimiters to "||"
                            set valuesList to text items of mediaInfo
                            if (count of valuesList) is greater than or equal to 2 then
                                set stateText to item 1 of valuesList
                                set volumeText to item 2 of valuesList
                                if stateText is "PLAYING" then set hasPlaying to true
                                set parsedVolume to (volumeText as real)
                                if parsedVolume > maxVolume then
                                    set maxVolume to parsedVolume
                                end if
                            end if
                            set AppleScript's text item delimiters to ""
                        end if
                    end try
                end repeat
            end repeat
            if not foundMedia then return "NO_MEDIA"
            set stateResult to "PAUSED"
            if hasPlaying then set stateResult to "PLAYING"
            return ((maxVolume * 100) as string) & "||" & stateResult
        end tell
        """

        guard session.isActive, let result = runAppleScript(script),
              result != "NOT_RUNNING",
              result != "NO_MEDIA"
        else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 2 else { return nil }

        let volumeValue = (Float(parts[0].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) / 100.0
        let isPlaying = parts[1].uppercased().contains("PLAYING")

        return MediaAppVolume(
            id: "chrome",
            appName: "Google Chrome",
            bundleIdentifier: "com.google.Chrome",
            iconName: "globe",
            volume: max(0, min(1, volumeValue)),
            isPlaying: isPlaying
        )
    }

    private func setChromeMediaVolume(_ volume: Float) {
        guard PermissionsManager.hasAutomationAccess(to: "com.google.Chrome"),
              PermissionsManager.hasAutomationAccess(to: "com.apple.systemevents"),
              isApplicationInstalled(bundleIdentifier: "com.google.Chrome"),
              isApplicationRunning(bundleIdentifier: "com.google.Chrome", processName: "Google Chrome") else {
            return
        }

        let normalized = String(format: "%.3f", max(0, min(1, volume)))
        let script = """
        tell application "System Events"
            if not (exists process "Google Chrome") then return
        end tell
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        execute t javascript "(function(){var media=document.querySelectorAll('video,audio');for(var i=0;i<media.length;i++){media[i].muted=false;media[i].volume=\(normalized);}})();"
                    end try
                end repeat
            end repeat
        end tell
        """
        let session = mediaWorkSession
        appleScriptQueue.async { [weak self] in
            guard session.isActive else { return }
            _ = self?.runAppleScript(script)
        }
    }

    nonisolated private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil {
            return nil
        }
        return result.stringValue
    }

    // MARK: - Helpers

    nonisolated private func isApplicationInstalled(bundleIdentifier: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    nonisolated private func isApplicationRunning(bundleIdentifier: String, processName: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard !app.isTerminated else { return false }
            return app.bundleIdentifier == bundleIdentifier || app.localizedName == processName
        }
    }

    var volumeIconName: String {
        if isMuted || volume == 0 {
            return "speaker.slash.fill"
        } else if volume < 0.33 {
            return "speaker.wave.1.fill"
        } else if volume < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    var volumePercentage: Int {
        Int(volume * 100)
    }

    deinit {
        let token = mediaRefreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(token)
        }
    }
}
