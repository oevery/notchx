import AppKit
import Combine

// MARK: - MediaRemote Function Types
private typealias MRMediaRemoteRegisterForNowPlayingNotificationsFunction = @convention(c) (DispatchQueue) -> Void
private typealias MRMediaRemoteSendCommandFunction = @convention(c) (UInt32, UnsafeMutableRawPointer?) -> Bool
private typealias MRMediaRemoteSetElapsedTimeFunction = @convention(c) (Double) -> Void

// MediaRemote command constants
private let kMRPlay: UInt32 = 0
private let kMRPause: UInt32 = 1
private let kMRTogglePlayPause: UInt32 = 2
private let kMRStop: UInt32 = 3
private let kMRNextTrack: UInt32 = 4
private let kMRPreviousTrack: UInt32 = 5

private let nowPlayingBrowserDetectionEnabledKey = SettingsDefaults.NowPlaying.browserDetection.key
private let nowPlayingAllowedBrowserBundleIDsKey = SettingsDefaults.NowPlaying.allowedBrowsers.key
private let nowPlayingDefaultAllowedBrowserBundleIDs = SettingsDefaults.NowPlaying.allowedBrowsers.value
private let nowPlayingSupportedBrowserTargets = [
    NowPlayingBrowserTarget(
        id: "com.google.Chrome",
        displayName: "Google Chrome",
        applicationName: "Google Chrome",
        processName: "Google Chrome"
    ),
    NowPlayingBrowserTarget(
        id: "com.google.Chrome.canary",
        displayName: "Google Chrome Canary",
        applicationName: "Google Chrome Canary",
        processName: "Google Chrome Canary"
    )
]

@MainActor
final class NowPlayingManager: ObservableObject {
    static let shared = NowPlayingManager()
    var onPlaybackAvailable: (() -> Void)?

    @Published var title: String = ""
    @Published var artist: String = ""
    @Published var album: String = ""
    @Published var albumArt: NSImage?
    @Published var albumArtColor: NSColor?
    @Published var isPlaying: Bool = false {
        didSet { updateCompactPlaybackGrace(wasPlaying: oldValue) }
    }
    @Published private var compactPlaybackGrace = CompactPlaybackGrace()
    @Published private var pausedPlaybackRetention = PausedPlaybackRetention()
    @Published var pauseRetentionSeconds = SettingsDefaults.NowPlaying.pauseRetention.read() {
        didSet {
            UserDefaults.standard.set(pauseRetentionSeconds, forKey: SettingsDefaults.NowPlaying.pauseRetention.key)
            scheduleCompactPlaybackExpiry()
        }
    }

    private var compactPlaybackGraceTask: Task<Void, Never>?
    @Published var duration: TimeInterval = 0
    @Published var elapsedTime: TimeInterval = 0
    @Published private(set) var hasKnownPosition = false
    @Published private(set) var shuffleMode: PlaybackShuffleMode?
    @Published private(set) var repeatMode: PlaybackRepeatMode?
    @Published var playbackRate: Double = 0
    @Published var sourceName: String = "" // "Spotify", "Apple Music", "Chrome", etc.
    @Published private(set) var controlError = ""
    @Published private(set) var isControlPending = false
    @Published private(set) var isPresentationPending = false
    @Published private(set) var pendingSeek: PendingPlaybackSeek?
    @Published var providerStatus: NowPlayingProviderStatus = .idle

    var isEligibleForCompactPresentation: Bool {
        (isPlaying && providerStatus.isLivePlayback) ||
            (providerStatus.canControlPlayback && (compactPlaybackGrace.isActive(at: Date()) ||
                (!isPlaying && pausedPlaybackRetention.isActive(seconds: pauseRetentionSeconds, at: Date()))))
    }

    var hasControllableTrack: Bool { !title.isEmpty && providerStatus.canControlPlayback }
    var canControlPlayback: Bool { hasControllableTrack && !isControlPending }
    var canSeek: Bool {
        hasControllableTrack && duration.isFinite && duration > 0 &&
            (shouldUseMediaRemoteControls || sourceName == "Spotify" || sourceName == "Apple Music")
    }
    var presentationTrackID: String {
        currentTrackIdentifier.isEmpty ? currentTrackSignature : currentBundleIdentifier + "||" + currentTrackIdentifier
    }
    var displayedElapsedTime: TimeInterval { pendingSeek?.position(at: Date()) ?? elapsedTime }
    var isSeeking: Bool { pendingSeek != nil }
    var canChangePlaybackMode: Bool { canControlPlayback && shouldUseMediaRemoteControls }
    var canOpenCurrentPlayer: Bool { isEnabled && !currentBundleIdentifier.isEmpty && !title.isEmpty }
    var favoriteContext: String? {
        guard isEnabled, currentBundleIdentifier == NetEaseFavoriteAccess.bundleID,
              hasControllableTrack else { return nil }
        return lifecycleGeneration.uuidString + currentTrackSignature
    }

    var playbackStatusDescription: String? {
        if !controlError.isEmpty { return controlError }
        switch providerStatus {
        case .stale, .unavailable: return providerStatus.title
        default: return nil
        }
    }
    @Published var browserDetectionTestMessage: String = ""
    @Published var browserDetectionEnabled: Bool = SettingsDefaults.NowPlaying.browserDetection.read() {
        didSet {
            UserDefaults.standard.set(browserDetectionEnabled, forKey: nowPlayingBrowserDetectionEnabledKey)
            browserDetectionTestMessage = ""
            if browserDetectionEnabled {
                refreshPreferredSource()
            } else if isBrowserPlaybackSource {
                clearCurrentTrack()
                providerStatus = .browserDisabled
            }
        }
    }
    @Published var allowedBrowserBundleIDs: Set<String> = Set(
        UserDefaults.standard.stringArray(forKey: nowPlayingAllowedBrowserBundleIDsKey) ?? nowPlayingDefaultAllowedBrowserBundleIDs
    ) {
        didSet {
            let ordered = nowPlayingSupportedBrowserTargets.map(\.id).filter { allowedBrowserBundleIDs.contains($0) }
            UserDefaults.standard.set(ordered, forKey: nowPlayingAllowedBrowserBundleIDsKey)
            if browserDetectionEnabled {
                refreshPreferredSource()
            }
        }
    }
    private var currentAlbumArtist: String = ""
    private var currentArtworkURL: String?
    private var currentTrackIdentifier: String = ""
    private var currentTrackIsLocalFile = false

    private var handle: UnsafeMutableRawPointer?
    private var registerFunc: MRMediaRemoteRegisterForNowPlayingNotificationsFunction?
    private var sendCommandFunc: MRMediaRemoteSendCommandFunction?
    private var setElapsedTimeFunc: MRMediaRemoteSetElapsedTimeFunction?

    private var sourceRefreshToken: ModuleRefreshToken?
    private var isEnabled = false
    private var lifecycleGeneration = UUID()
    private var playbackRefreshToken: ModuleRefreshToken?
    private var lastPlaybackTickDate: Date?
    private var cancellables = Set<AnyCancellable>()

    // Track whether MediaRemote is providing data
    private var mediaRemoteActive = false
    // Track last detected title to avoid re-activating the module on every poll
    private var lastDetectedTitle: String = ""
    // Track the most recent Chrome media tab and the last one paused by our controls.
    private var currentChromeTabURL: String = ""
    private var lastPausedChromeTabURL: String = ""
    private var currentBundleIdentifier: String = ""
    private var lastKnownSnapshot: NowPlayingSnapshot?
    private var providerRefreshTask: Task<Void, Never>?
    private var browserDetectionTask: Task<Void, Never>?
    private var controlRefreshTask: Task<Void, Never>?
    private var artworkClearTask: Task<Void, Never>?
    private var artworkLookupTask: Task<Void, Never>?
    private var artworkDownloadTask: URLSessionDataTask?
    private var artworkRequestID = UUID()
    private var albumArtColorRequestID = UUID()
    private var pendingAppleScriptJobs: [UUID: () -> Void] = [:]
    private var adapterStartupTask: Task<Void, Never>?
    private var adapterAttemptID = UUID()
    private var adapterEventRevision = 0
    private var adapterRetryCount = 0
    private var adapterRestartTask: Task<Void, Never>?
    private var adapterReadTask: Task<Void, Never>?
    private var adapterControlTask: Task<Void, Never>?
    private var modeConfirmationTask: Task<Void, Never>?
    private var pendingModeCommand: PlaybackModeCommand?
    private var seekTask: Task<Void, Never>?
    private var endpointCalibrationKey: String?
    private var adapterProcess: Process?
    private var adapterPipeHandler: JSONLinesPipeHandler?
    private var adapterStreamTask: Task<Void, Never>?
    private var adapterDidDeliverUpdate = false
    private var publication = NetEasePlaybackPublication()
    private var publicationTask: Task<Void, Never>?
    private var publicationRevision = UUID()
    private var artworkDecoder = PlaybackArtworkDecoder()
    private var adapterSnapshot: NowPlayingPayload?
    private var adapterPositionAnchor: NowPlayingPayload?
    private let appleScriptQueue = DispatchQueue(label: "app.notchx.applescript", qos: .userInitiated)

    private init() {
        loadMediaRemote()
    }

    private func updateCompactPlaybackGrace(wasPlaying: Bool) {
        guard wasPlaying != isPlaying else { return }
        let now = Date()
        compactPlaybackGrace.update(wasPlaying: wasPlaying, isPlaying: isPlaying, enabled: isEnabled, at: now)
        pausedPlaybackRetention.update(isPlaying: isPlaying, enabled: isEnabled, at: now)
        scheduleCompactPlaybackExpiry()
    }

    private func scheduleCompactPlaybackExpiry() {
        compactPlaybackGraceTask?.cancel()
        compactPlaybackGraceTask = nil
        let now = Date()
        let deadlines = [compactPlaybackGrace.deadline, pausedPlaybackRetention.deadline(seconds: pauseRetentionSeconds)]
            .compactMap { $0 }.filter { $0 > now }
        guard let deadline = deadlines.max() else { return }
        let generation = lifecycleGeneration
        compactPlaybackGraceTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) } catch { return }
            guard let self, !Task.isCancelled, self.lifecycleGeneration == generation else { return }
            // Keep the original pause instant: changing the setting must not restart its timer.
            self.objectWillChange.send()
            self.compactPlaybackGraceTask = nil
        }
    }

    /// Synchronize a confirmed preference restore without changing activation or permissions.
    func reloadRestoredPreferences() {
        pauseRetentionSeconds = SettingsDefaults.NowPlaying.pauseRetention.read()
        // Detection is off by default; apply it before the browser allowlist.
        browserDetectionEnabled = SettingsDefaults.NowPlaying.browserDetection.read()
        allowedBrowserBundleIDs = Set(SettingsDefaults.NowPlaying.allowedBrowsers.read())
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        lifecycleGeneration = UUID()
        if enabled {
            observeAlbumArtColor()
            registerForNotifications()
            observeSpotify()
            observeSourceTermination()
            startPolling()
            refreshPreferredSource()
            let generation = lifecycleGeneration
            adapterStartupTask = Task { [weak self] in
                await self?.startMediaRemoteAdapterObserver(generation: generation)
            }
        } else {
            onPlaybackAvailable = nil
            cancelSeek()
            NotificationCenter.default.removeObserver(self)
            DistributedNotificationCenter.default().removeObserver(self)
            ModuleRefreshScheduler.shared.unregister(sourceRefreshToken)
            ModuleRefreshScheduler.shared.unregister(playbackRefreshToken)
            sourceRefreshToken = nil
            playbackRefreshToken = nil
            lastPlaybackTickDate = nil
            providerRefreshTask?.cancel()
            providerRefreshTask = nil
            browserDetectionTask?.cancel()
            browserDetectionTask = nil
            controlRefreshTask?.cancel()
            controlRefreshTask = nil
            cancelArtworkRequests()
            cancellables.removeAll()
            albumArtColorRequestID = UUID()
            for cancel in pendingAppleScriptJobs.values { cancel() }
            pendingAppleScriptJobs.removeAll()
            adapterStartupTask?.cancel()
            adapterStartupTask = nil
            adapterRestartTask?.cancel()
            adapterRestartTask = nil
            adapterReadTask?.cancel()
            adapterReadTask = nil
            adapterControlTask?.cancel()
            adapterControlTask = nil
            cancelModeConfirmation()
            adapterAttemptID = UUID()
            adapterRetryCount = 0
            isControlPending = false
            controlError = ""
            adapterStreamTask?.cancel()
            adapterStreamTask = nil
            let pipe = adapterPipeHandler
            adapterPipeHandler = nil
            if let process = adapterProcess {
                AdapterProcessRunner.stopOwnedProcess(process)
            }
            adapterProcess = nil
            adapterDidDeliverUpdate = false
            adapterSnapshot = nil
            adapterPositionAnchor = nil
            clearCurrentTrack()
            Task { await pipe?.close() }
        }
    }

    // MARK: - Polling

    private func observeSourceTermination() {
        let generation = lifecycleGeneration
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, self.isEnabled, self.lifecycleGeneration == generation,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleID = application.bundleIdentifier, bundleID == self.currentBundleIdentifier else { return }
                self.invalidateCurrentSource()
                self.refreshPreferredSource()
            }
            .store(in: &cancellables)
    }

    private var currentSourceIsRunning: Bool {
        currentBundleIdentifier.isEmpty || NSRunningApplication.runningApplications(
            withBundleIdentifier: currentBundleIdentifier
        ).contains { !$0.isTerminated }
    }

    private func invalidateCurrentSource() {
        adapterDidDeliverUpdate = false
        mediaRemoteActive = false
        if !showLastKnownSnapshotIfUseful() { clearCurrentTrack() }
    }

    private func startPolling() {
        guard isEnabled else { return }
        let generation = lifecycleGeneration
        sourceRefreshToken = ModuleRefreshScheduler.shared.register(
            id: "nowPlaying.source",
            name: "Now Playing fallback refresh",
            module: .builtIn(.nowPlaying),
            policy: .interval(5, tolerance: 2),
            enabled: { [weak self] in self?.isEnabled == true }
        ) { [weak self] in
            guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
            self.refreshPreferredSource()
        }
    }

    // MARK: - MediaRemote Loading

    private func loadMediaRemote() {
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW)
        guard handle != nil else {
            print("[NowPlaying] Failed to load MediaRemote framework")
            return
        }

        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            registerFunc = unsafeBitCast(sym, to: MRMediaRemoteRegisterForNowPlayingNotificationsFunction.self)
        }

        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommandFunc = unsafeBitCast(sym, to: MRMediaRemoteSendCommandFunction.self)
        }

        if let sym = dlsym(handle, "MRMediaRemoteSetElapsedTime") {
            setElapsedTimeFunc = unsafeBitCast(sym, to: MRMediaRemoteSetElapsedTimeFunction.self)
        }
    }

    // MARK: - Registration

    private func registerForNotifications() {
        registerFunc?(DispatchQueue.main)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingInfoDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingInfoDidChangeNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingApplicationIsPlayingDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"),
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(nowPlayingApplicationDidChange),
            name: NSNotification.Name("kMRMediaRemoteNowPlayingApplicationDidChangeNotification"),
            object: nil
        )
    }

    // MARK: - Spotify Distributed Notifications

    private func observeAlbumArtColor() {
        let generation = lifecycleGeneration
        $albumArt
            .removeDuplicates { $0?.tiffRepresentation == $1?.tiffRepresentation }
            .sink { [weak self] image in
                guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
                let requestID = UUID()
                self.albumArtColorRequestID = requestID
                guard let image else {
                    self.albumArtColor = nil
                    return
                }
                image.averageColor { [weak self] color in
                    guard let self, self.isEnabled, self.lifecycleGeneration == generation,
                          self.albumArtColorRequestID == requestID, let color else { return }
                    let rgb = color.usingColorSpace(.sRGB) ?? color
                    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                    rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                    self.albumArtColor = NSColor(
                        hue: h,
                        saturation: min(max(s * 1.15, 0.55), 1.0),
                        brightness: min(max(b * 1.18, 0.72), 1.0),
                        alpha: a
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func observeSpotify() {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(spotifyStateChanged),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil
        )
    }

    @objc private func spotifyStateChanged(_ notification: Notification) {
        refreshPreferredSource()
    }

    // MARK: - Notification Handlers

    @objc private func nowPlayingInfoDidChange() {
        refreshPreferredSource()
    }

    @objc private func nowPlayingApplicationIsPlayingDidChange() {
        refreshPreferredSource()
    }

    @objc private func nowPlayingApplicationDidChange() {
        refreshPreferredSource()
    }

    // MARK: - MediaRemote Adapter

    private func startMediaRemoteAdapterObserver(generation: UUID) async {
        guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled, adapterProcess == nil else { return }
        guard let resources = mediaRemoteAdapterResources() else {
            print("[NowPlaying] MediaRemote adapter resources not found")
            return
        }

        let attemptID = UUID()
        adapterAttemptID = attemptID
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // Keep position and timestamp together. Diff streams can omit an
        // unchanged position when a new timestamp arrives (including real seeks).
        process.arguments = [resources.scriptURL.path, resources.frameworkURL.path, "stream", "--no-diff"]

        let pipeHandler = JSONLinesPipeHandler()
        process.standardOutput = await pipeHandler.getPipe()
        guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled else {
            await pipeHandler.close()
            return
        }

        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.adapterDisconnected(generation: generation, attemptID: attemptID)
            }
        }

        adapterProcess = process
        adapterPipeHandler = pipeHandler

        do {
            try process.run()
            adapterStreamTask = Task { [weak self] in
                await self?.processAdapterJSONStream(pipeHandler: pipeHandler, generation: generation, attemptID: attemptID)
            }
        } catch {
            print("[NowPlaying] Failed to launch MediaRemote adapter: \(error)")
            adapterDisconnected(generation: generation, attemptID: attemptID)
        }
    }

    private func processAdapterJSONStream(pipeHandler: JSONLinesPipeHandler, generation: UUID, attemptID: UUID) async {
        guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled else { return }
        await pipeHandler.readJSONLines(as: NowPlayingUpdate.self) { [weak self] update in
            guard let self, self.adapterAttemptID == attemptID else { return }
            await self.handleAdapterUpdate(update, generation: generation)
        }
        adapterDisconnected(generation: generation, attemptID: attemptID)
    }

    private func adapterDisconnected(generation: UUID, attemptID: UUID) {
        guard isEnabled, lifecycleGeneration == generation, adapterAttemptID == attemptID else { return }
        cancelPendingPublication()
        cancelSeek()
        adapterAttemptID = UUID()
        if let adapterProcess { AdapterProcessRunner.stopOwnedProcess(adapterProcess) }
        adapterProcess = nil
        let pipe = adapterPipeHandler
        adapterPipeHandler = nil
        adapterStreamTask?.cancel()
        adapterStreamTask = nil
        adapterReadTask?.cancel()
        adapterReadTask = nil
        adapterControlTask?.cancel()
        adapterControlTask = nil
        cancelModeConfirmation()
        isControlPending = false
        adapterDidDeliverUpdate = false
        adapterSnapshot = nil
        adapterPositionAnchor = nil
        invalidateCurrentSource()
        refreshPreferredSource()
        Task { await pipe?.close() }
        adapterRetryCount = min(adapterRetryCount + 1, 6)
        let delay = min(pow(2, Double(adapterRetryCount - 1)), 30)
        adapterRestartTask?.cancel()
        adapterRestartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled else { return }
            await self.startMediaRemoteAdapterObserver(generation: generation)
        }
    }

    private func handleAdapterUpdate(_ update: NowPlayingUpdate, generation: UUID, fromStream: Bool = true, settled: Bool = false) async {
        guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled else { return }
        guard update.type == nil || update.type == "data" else { return }
        if fromStream {
            adapterReadTask?.cancel()
            adapterReadTask = nil
        }
        adapterEventRevision += 1
        adapterRetryCount = 0
        providerRefreshTask?.cancel()
        providerRefreshTask = nil
        adapterDidDeliverUpdate = true

        if !settled {
            if update.diff == true {
                cancelPendingPublication()
            } else {
                let ready = publication.receive(update.payload, at: Date())
                publicationTask?.cancel()
                publicationRevision = UUID()
                isPresentationPending = publication.pending != nil
                if isPresentationPending { cancelSeek() }
                if ready == nil {
                    schedulePublication(generation: generation)
                    return
                }
            }
        }

        let diff = update.diff ?? false
        // Diffs distinguish omitted fields (retain) from explicit null (remove).
        let previousPayload = adapterSnapshot
        let payload = update.payload.applying(to: previousPayload, diff: diff)
        adapterSnapshot = payload
        let previousElapsedTime = hasKnownPosition ? projectedElapsedTime(at: Date()) : nil
        let bundleIdentifier = payload.sourceBundleIdentifier
        let resolvedTitle = payload.title ?? ""
        let resolvedArtist = payload.artist ?? ""
        let resolvedAlbum = payload.album ?? ""
        let resolvedAlbumArtist = payload.albumArtist ?? ""
        let resolvedDuration = payload.duration ?? 0
        let resolvedPlaybackRate = payload.playbackRate ?? 1.0
        let resolvedIsPlaying = payload.playing ?? false
        let resolvedSourceName = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Unknown"
            : sourceName(forBundleIdentifier: bundleIdentifier)
        let resolvedTrackIdentifier = payload.stableIdentifier
        let resolvedIsLocalFile = payload.isLocalFile ?? false
        let trackChanged = previousPayload.map { !payload.isSameTrack(as: $0) } ?? true
        let receivedAt = Date()
        let resolvedElapsedTime = payload.calibratedElapsedTime(
            incoming: update.payload, previous: adapterPositionAnchor, diff: diff, previousElapsed: previousElapsedTime,
            trackChanged: trackChanged, now: receivedAt
        )
        if trackChanged || update.payload.contains(.elapsedTime) {
            adapterPositionAnchor = update.payload.elapsedTime == nil ? nil : update.payload
        }

        if resolvedTitle.isEmpty, bundleIdentifier.isEmpty {
            clearCurrentTrack()
            return
        }

        if trackChanged || resolvedTrackIdentifier != currentTrackIdentifier {
            cancelArtworkRequests()
            cancelSeek()
            controlError = ""
        }
        if currentBundleIdentifier != bundleIdentifier {
            adapterControlTask?.cancel()
            adapterControlTask = nil
            cancelModeConfirmation()
            isControlPending = false
        }
        mediaRemoteActive = !resolvedTitle.isEmpty || !bundleIdentifier.isEmpty
        currentBundleIdentifier = bundleIdentifier
        currentAlbumArtist = resolvedAlbumArtist
        currentTrackIdentifier = resolvedTrackIdentifier
        currentTrackIsLocalFile = resolvedIsLocalFile
        title = resolvedTitle
        artist = resolvedArtist
        album = resolvedAlbum
        duration = resolvedDuration
        playbackRate = resolvedPlaybackRate
        isPlaying = resolvedIsPlaying
        sourceName = resolvedSourceName
        providerStatus = resolvedIsPlaying ? .playing(resolvedSourceName) : .paused(resolvedSourceName)

        hasKnownPosition = resolvedElapsedTime != nil
        elapsedTime = resolvedElapsedTime ?? 0
        shuffleMode = payload.shuffleMode
        repeatMode = payload.repeatMode
        confirmPlaybackModeIfNeeded()
        if update.payload.contains(.elapsedTime) {
            confirmSeek(position: resolvedElapsedTime, sampledAt: update.payload.timestampDate)
        }

        if isChromeBundleIdentifier(bundleIdentifier) {
            if !resolvedIsPlaying && !currentChromeTabURL.isEmpty {
                lastPausedChromeTabURL = currentChromeTabURL
            }
        } else {
            currentChromeTabURL = ""
            lastPausedChromeTabURL = ""
        }

        if trackChanged || update.payload.contains(.artworkData) || !diff {
            let decoded = artworkDecoder.decode(payload.artworkData)
            if let decoded {
                artworkClearTask?.cancel()
                artworkClearTask = nil
                if albumArt !== decoded { albumArt = decoded }
            } else if trackChanged || payload.artworkData != previousPayload?.artworkData {
                artworkClearTask?.cancel()
                artworkClearTask = nil
                if albumArt != nil {
                    // Retain the outgoing image briefly for a separate artwork event.
                    let signature = currentTrackSignature
                    artworkClearTask = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        guard let self, self.isEnabled, self.lifecycleGeneration == generation,
                              self.currentTrackSignature == signature else { return }
                        self.albumArt = nil
                        self.artworkClearTask = nil
                    }
                }
            }
            currentArtworkURL = nil
        } else if resolvedTitle.isEmpty {
            albumArt = nil
            currentArtworkURL = nil
        }

        rememberCurrentSnapshot(providerID: "mediaRemoteAdapter")

        guard currentSourceIsRunning else {
            invalidateCurrentSource()
            return
        }

        if resolvedIsPlaying, !resolvedTitle.isEmpty, resolvedTitle != lastDetectedTitle {
            lastDetectedTitle = resolvedTitle
            onPlaybackAvailable?()
        } else if resolvedTitle.isEmpty {
            lastDetectedTitle = ""
        }

        updatePlaybackTimer()
    }

    private func cancelPendingPublication() {
        publicationRevision = UUID()
        publicationTask?.cancel()
        publicationTask = nil
        publication.reset()
        isPresentationPending = false
    }

    private func schedulePublication(generation: UUID) {
        publicationTask?.cancel()
        publicationRevision = UUID()
        guard let deadline = publication.deadline else { return }
        let revision = publicationRevision
        publicationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard let self, !Task.isCancelled, self.isEnabled,
                  self.lifecycleGeneration == generation, self.publicationRevision == revision,
                  let payload = self.publication.flush(at: Date()) else { return }
            self.publicationTask = nil
            self.isPresentationPending = false
            await self.handleAdapterUpdate(NowPlayingUpdate(payload: payload, diff: false),
                                           generation: generation, fromStream: false, settled: true)
        }
    }

    private func calibrateAtTrackEnd() {
        let key = currentTrackSignature
        guard endpointCalibrationKey != key else { return }
        endpointCalibrationKey = key
        if shouldUseMediaRemoteControls { requestAdapterCalibration() }
        else { refreshPreferredSource() }
    }

    private func requestAdapterCalibration() {
        guard isEnabled, adapterReadTask == nil, let resources = mediaRemoteAdapterResources() else { return }
        let generation = lifecycleGeneration
        let attemptID = adapterAttemptID
        let revision = adapterEventRevision
        adapterReadTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.adapterAttemptID == attemptID, self.adapterEventRevision == revision { self.adapterReadTask = nil } }
            do {
                let data = try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                    arguments: [resources.scriptURL.path, resources.frameworkURL.path, "get"])
                guard self.isEnabled, self.lifecycleGeneration == generation, self.adapterAttemptID == attemptID,
                      self.adapterEventRevision == revision, !Task.isCancelled else { return }
                let payload = try JSONDecoder().decode(NowPlayingPayload?.self, from: data)
                self.adapterReadTask = nil
                if let payload {
                    await self.handleAdapterUpdate(NowPlayingUpdate(payload: payload, diff: false), generation: generation, fromStream: false)
                } else {
                    self.adapterSnapshot = nil
                    self.clearCurrentTrack()
                }
            } catch {
                guard self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled else { return }
                self.controlError = L10n.text("Unable to refresh playback. Waiting for the player.")
            }
        }
    }

    private func sendAdapterControl(_ arguments: [String], confirming mode: PlaybackModeCommand? = nil) {
        guard let resources = mediaRemoteAdapterResources() else {
            publication.cancelPlaybackIntent()
            controlError = L10n.text("Playback command failed. Please try again.")
            return
        }
        adapterControlTask?.cancel()
        cancelModeConfirmation()
        let generation = lifecycleGeneration
        let source = currentBundleIdentifier
        isControlPending = true
        controlError = ""
        adapterControlTask = Task { [weak self] in
            guard let self else { return }
            guard self.currentBundleIdentifier == source, !Task.isCancelled else {
                self.isControlPending = false
                return
            }
            do {
                _ = try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                    arguments: [resources.scriptURL.path, resources.frameworkURL.path] + arguments)
                guard self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled else { return }
                self.isControlPending = false
                self.endpointCalibrationKey = nil
                if self.currentBundleIdentifier == source {
                    if let mode { self.waitForPlaybackMode(mode, source: source, generation: generation) }
                    self.requestAdapterCalibration()
                }
            } catch {
                guard self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled else { return }
                self.publication.cancelPlaybackIntent()
                self.isControlPending = false
                guard self.currentBundleIdentifier == source else { return }
                self.controlError = L10n.text("Playback command failed. Please try again.")
                self.requestAdapterCalibration()
            }
        }
    }

    private func waitForPlaybackMode(_ command: PlaybackModeCommand, source: String, generation: UUID) {
        guard !command.isConfirmed(shuffle: shuffleMode, repeatMode: repeatMode) else { return }
        pendingModeCommand = command
        isControlPending = true
        modeConfirmationTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.isEnabled, self.lifecycleGeneration == generation,
                  self.currentBundleIdentifier == source, self.pendingModeCommand == command else { return }
            self.cancelModeConfirmation()
            self.controlError = L10n.text("The player did not confirm this playback mode.")
        }
    }

    private func confirmPlaybackModeIfNeeded() {
        guard let command = pendingModeCommand,
              command.isConfirmed(shuffle: shuffleMode, repeatMode: repeatMode) else { return }
        cancelModeConfirmation()
        controlError = ""
    }

    private func cancelModeConfirmation() {
        modeConfirmationTask?.cancel()
        modeConfirmationTask = nil
        if pendingModeCommand != nil { isControlPending = false }
        pendingModeCommand = nil
    }

    private func mediaRemoteAdapterResources() -> (scriptURL: URL, frameworkURL: URL)? {
        let fm = FileManager.default

        // Xcode copies the .pl script to Contents/Resources and the .framework to
        // Contents/Frameworks — check those canonical bundle locations first.
        if let resourceURL = Bundle.main.resourceURL,
           let frameworksURL = Bundle.main.privateFrameworksURL {
            let scriptURL = resourceURL.appendingPathComponent("mediaremote-adapter.pl")
            let frameworkURL = frameworksURL.appendingPathComponent("MediaRemoteAdapter.framework")
            if fm.fileExists(atPath: scriptURL.path),
               fm.fileExists(atPath: frameworkURL.path) {
                return (scriptURL, frameworkURL)
            }
        }

        // Legacy layout: both files inside a MediaRemoteAdapter/ subfolder in Resources.
        if let resourceURL = Bundle.main.resourceURL {
            let dir = resourceURL.appendingPathComponent("MediaRemoteAdapter", isDirectory: true)
            let scriptURL = dir.appendingPathComponent("mediaremote-adapter.pl")
            let frameworkURL = dir.appendingPathComponent("MediaRemoteAdapter.framework")
            if fm.fileExists(atPath: scriptURL.path),
               fm.fileExists(atPath: frameworkURL.path) {
                return (scriptURL, frameworkURL)
            }
        }

        // Dev fallback: resolve relative to source file (only works on the build machine).
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let adapterDirectory = sourceRoot.appendingPathComponent("Resources/MediaRemoteAdapter", isDirectory: true)
        let scriptURL = adapterDirectory.appendingPathComponent("mediaremote-adapter.pl")
        let frameworkURL = adapterDirectory.appendingPathComponent("MediaRemoteAdapter.framework")

        guard fm.fileExists(atPath: scriptURL.path),
              fm.fileExists(atPath: frameworkURL.path) else {
            return nil
        }

        return (scriptURL, frameworkURL)
    }

    // MARK: - AppleScript Fallback

    private func refreshPreferredSource() {
        guard isEnabled else { return }
        if adapterDidDeliverUpdate, !title.isEmpty {
            if adapterProcess?.isRunning == true, currentSourceIsRunning {
                if providerStatus.isHistory, !showLastKnownSnapshotIfUseful() { clearCurrentTrack() }
                return
            }
            invalidateCurrentSource()
        }

        let currentSource = sourceName
        let generation = lifecycleGeneration
        providerRefreshTask?.cancel()
        providerRefreshTask = Task { [weak self] in
            await self?.refreshProviderSnapshots(preferredSourceName: currentSource, generation: generation)
        }
    }

    private func refreshProviderSnapshots(preferredSourceName: String, generation: UUID) async {
        guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled else { return }
        var fallbackSnapshot: NowPlayingSnapshot?

        for provider in scriptProviders(preferredSourceName: preferredSourceName) {
            guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled else { return }
            if title.isEmpty { providerStatus = .checking(provider.displayName) }
            guard let snapshot = await provider.currentSnapshot() else { continue }
            guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled else { return }

            if snapshot.isPlaying {
                applySnapshot(snapshot)
                fetchArtworkIfNeeded(for: snapshot)
                mediaRemoteActive = false
                return
            }

            if fallbackSnapshot == nil {
                fallbackSnapshot = snapshot
            }
        }

        guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled else { return }
        if let fallbackSnapshot {
            applySnapshot(fallbackSnapshot)
            fetchArtworkIfNeeded(for: fallbackSnapshot)
            mediaRemoteActive = false
            return
        }

        if showLastKnownSnapshotIfUseful() {
            return
        }

        clearCurrentTrack()
    }

    private func scriptProviders(preferredSourceName: String) -> [any NowPlayingProvider] {
        var providers: [any NowPlayingProvider] = []

        switch preferredSourceName {
        case "Spotify":
            providers.append(spotifyProvider)
        case "Apple Music":
            providers.append(musicProvider)
        case "YouTube", "YouTube Music", "SoundCloud", "Spotify Web", "Google Chrome", "Google Chrome Canary":
            if browserDetectionEnabled {
                providers.append(browserProvider)
            }
        default:
            break
        }

        providers.append(spotifyProvider)
        providers.append(musicProvider)

        if browserDetectionEnabled {
            providers.append(browserProvider)
        }

        var seen = Set<String>()
        return providers.filter { seen.insert($0.id).inserted }
    }

    private var spotifyProvider: any NowPlayingProvider {
        NowPlayingScriptProvider(
            id: "spotify",
            displayName: "Spotify",
            requiresPermission: true,
            currentSnapshot: { [weak self] in
                guard let self else { return nil }
                return await self.runOnAppleScriptQueue {
                    self.spotifySnapshotViaAppleScript(allowPausedFallback: true)
                }
            }
        )
    }

    private var musicProvider: any NowPlayingProvider {
        NowPlayingScriptProvider(
            id: "appleMusic",
            displayName: "Apple Music",
            requiresPermission: true,
            currentSnapshot: { [weak self] in
                guard let self else { return nil }
                return await self.runOnAppleScriptQueue {
                    self.musicSnapshotViaAppleScript(allowPausedFallback: true)
                }
            }
        )
    }

    private var browserProvider: any NowPlayingProvider {
        NowPlayingScriptProvider(
            id: "browser",
            displayName: "Browser",
            requiresPermission: true,
            currentSnapshot: { [weak self] in
                guard let self else { return nil }
                return await self.runOnAppleScriptQueue {
                    self.browserSnapshotViaAppleScript(allowPausedFallback: true)
                }
            }
        )
    }

    private func runOnAppleScriptQueue<T>(_ work: @escaping () -> T?) async -> T? {
        guard isEnabled, !Task.isCancelled else { return nil }
        let generation = lifecycleGeneration
        let jobID = UUID()
        let job = NowPlayingScriptJob<T>()
        pendingAppleScriptJobs[jobID] = { job.cancel() }
        defer { pendingAppleScriptJobs[jobID] = nil }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                job.enqueue(on: appleScriptQueue, continuation: continuation, work: work)
            }
        } onCancel: {
            job.cancel()
        }
        guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled else { return nil }
        return result
    }

    private var shouldUseMediaRemoteControls: Bool {
        mediaRemoteActive || (adapterDidDeliverUpdate && !currentBundleIdentifier.isEmpty)
    }

    nonisolated private func spotifySnapshotViaAppleScript(allowPausedFallback: Bool) -> NowPlayingSnapshot? {
        guard PermissionsManager.hasAutomationAccess(to: "com.spotify.client"),
              PermissionsManager.hasAutomationAccess(to: "com.apple.systemevents"),
              isApplicationInstalled(bundleIdentifier: "com.spotify.client") else { return nil }
        let pausedReturn = allowPausedFallback ? "or player state is paused" : ""
        let script = """
        tell application "System Events"
            if not (exists process "Spotify") then return "NOT_RUNNING"
        end tell
        tell application "Spotify"
            if player state is playing \(pausedReturn) then
                set playbackState to player state as string
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                set trackURL to ""
                try
                    set trackURL to spotify url of current track
                end try
                return playbackState & "||" & trackName & "||" & trackArtist & "||" & trackAlbum & "||" & (trackDuration / 1000) & "||" & trackPosition & "||" & trackURL
            else
                return "NOT_PLAYING"
            end if
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING", result != "NOT_PLAYING" else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 7 else { return nil }

        let trackURL = parts[6]
        return NowPlayingSnapshot(
            providerID: "spotify",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: TimeInterval(parts[4]) ?? 0,
            elapsedTime: TimeInterval(parts[5]) ?? 0,
            playbackRate: parts[0] == "playing" ? 1 : 0,
            isPlaying: parts[0] == "playing",
            sourceName: "Spotify",
            bundleIdentifier: "com.spotify.client",
            albumArtist: parts[2],
            artworkURL: nil,
            trackIdentifier: trackURL,
            isLocalFile: trackURL.isEmpty,
            browserTabURL: "",
            capturedAt: Date()
        )
    }

    private func fetchSpotifyArtwork() {
        guard isEnabled else { return }
        artworkLookupTask?.cancel()
        let generation = lifecycleGeneration
        let signature = currentTrackSignature
        artworkLookupTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let urlString = await self.runOnAppleScriptQueue {
                guard PermissionsManager.hasAutomationAccess(to: "com.spotify.client"),
                      self.isApplicationInstalled(bundleIdentifier: "com.spotify.client") else { return nil as String? }
                return self.runAppleScript("tell application \"Spotify\" to return artwork url of current track")
            }
            guard self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled,
                  self.currentTrackSignature == signature, let urlString else { return }
            self.fetchRemoteArtwork(from: urlString)
        }
    }

    nonisolated private func musicSnapshotViaAppleScript(allowPausedFallback: Bool) -> NowPlayingSnapshot? {
        guard PermissionsManager.hasAutomationAccess(to: "com.apple.Music"),
              PermissionsManager.hasAutomationAccess(to: "com.apple.systemevents"),
              isApplicationInstalled(bundleIdentifier: "com.apple.Music") else { return nil }
        let pausedReturn = allowPausedFallback ? "or player state is paused" : ""
        let script = """
        tell application "System Events"
            if not (exists process "Music") then return "NOT_RUNNING"
        end tell
        tell application "Music"
            if player state is playing \(pausedReturn) then
                set playbackState to player state as string
                set trackName to name of current track
                set trackArtist to artist of current track
                set trackAlbum to album of current track
                set trackDuration to duration of current track
                set trackPosition to player position
                set trackAlbumArtist to ""
                try
                    set trackAlbumArtist to album artist of current track
                end try
                set trackPersistentID to ""
                try
                    set trackPersistentID to persistent ID of current track
                end try
                set trackLocation to ""
                try
                    set trackLocation to POSIX path of (location of current track)
                end try
                return playbackState & "||" & trackName & "||" & trackArtist & "||" & trackAlbum & "||" & trackDuration & "||" & trackPosition & "||" & trackAlbumArtist & "||" & trackPersistentID & "||" & trackLocation
            else
                return "NOT_PLAYING"
            end if
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING", result != "NOT_PLAYING" else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 9 else { return nil }

        return NowPlayingSnapshot(
            providerID: "appleMusic",
            title: parts[1],
            artist: parts[2],
            album: parts[3],
            duration: TimeInterval(parts[4]) ?? 0,
            elapsedTime: TimeInterval(parts[5]) ?? 0,
            playbackRate: parts[0] == "playing" ? 1 : 0,
            isPlaying: parts[0] == "playing",
            sourceName: "Apple Music",
            bundleIdentifier: "com.apple.Music",
            albumArtist: parts[6],
            artworkURL: nil,
            trackIdentifier: parts[7],
            isLocalFile: !parts[8].isEmpty,
            browserTabURL: "",
            capturedAt: Date()
        )
    }

    private func fetchChromeViaAppleScript(allowPausedFallback: Bool = true) async {
        let generation = lifecycleGeneration
        let snapshot = await runOnAppleScriptQueue {
            self.browserSnapshotViaAppleScript(allowPausedFallback: allowPausedFallback)
        }
        guard isEnabled, lifecycleGeneration == generation, !Task.isCancelled, let snapshot else { return }
        applySnapshot(snapshot)
        fetchArtworkIfNeeded(for: snapshot)
    }

    nonisolated private func browserSnapshotViaAppleScript(allowPausedFallback: Bool) -> NowPlayingSnapshot? {
        guard UserDefaults.standard.bool(forKey: nowPlayingBrowserDetectionEnabledKey) else { return nil }

        var pausedSnapshot: NowPlayingSnapshot?
        let allowedBundleIDs = Set(
            UserDefaults.standard.stringArray(forKey: nowPlayingAllowedBrowserBundleIDsKey) ?? nowPlayingDefaultAllowedBrowserBundleIDs
        )
        let targets = nowPlayingSupportedBrowserTargets.filter { allowedBundleIDs.contains($0.id) }

        for target in targets {
            guard let snapshot = browserSnapshotViaAppleScript(for: target, allowPausedFallback: allowPausedFallback) else {
                continue
            }
            if snapshot.isPlaying {
                return snapshot
            }
            if pausedSnapshot == nil {
                pausedSnapshot = snapshot
            }
        }
        return pausedSnapshot
    }

    nonisolated private func browserSnapshotViaAppleScript(
        for target: NowPlayingBrowserTarget,
        allowPausedFallback: Bool
    ) -> NowPlayingSnapshot? {
        guard PermissionsManager.hasAutomationAccess(to: target.id),
              PermissionsManager.hasAutomationAccess(to: "com.apple.systemevents"),
              isApplicationInstalled(bundleIdentifier: target.id) else { return nil }
        let pausedReturn = allowPausedFallback
            ? "if pausedURL is not \"\" then return \"PAUSED_TAB||\" & pausedTitle & \"||\" & pausedURL & \"||\" & pausedInfo"
            : ""
        let processName = escapeAppleScriptString(target.processName)
        let applicationName = escapeAppleScriptString(target.applicationName)
        let script = """
        tell application "System Events"
            if not (exists process "\(processName)") then return "NOT_RUNNING"
        end tell
        tell application "\(applicationName)"
            set playingTitle to ""
            set playingURL to ""
            set playingInfo to ""
            set pausedTitle to ""
            set pausedURL to ""
            set pausedInfo to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set mediaInfo to execute t javascript "
                            (function() {
                                var media = Array.from(document.querySelectorAll('video,audio'));
                                if (!media.length) return 'NO_MEDIA';
                                var active = media.find(function(item) { return !item.paused && !item.ended; });
                                var candidate = active || media.find(function(item) { return !item.ended; }) || media[0];
                                if (!candidate) return 'NO_MEDIA';
                                var metaImage = document.querySelector('meta[property=\"og:image\"], meta[name=\"twitter:image\"], link[rel=\"image_src\"]');
                                var thumbnail = candidate.poster || (metaImage ? (metaImage.content || metaImage.href || '') : '');
                                return (active ? 'PLAYING' : 'PAUSED') + '||' + candidate.currentTime + '||' + candidate.duration + '||' + thumbnail;
                            })();
                        "
                        if mediaInfo starts with "PLAYING||" then
                            set playingTitle to title of t
                            set playingURL to URL of t
                            set playingInfo to mediaInfo
                            exit repeat
                        else if mediaInfo starts with "PAUSED||" then
                            if pausedURL is "" then
                                set pausedTitle to title of t
                                set pausedURL to URL of t
                                set pausedInfo to mediaInfo
                            end if
                        end if
                    end try
                end repeat
                if playingURL is not "" then exit repeat
            end repeat
            if playingURL is not "" then return "PLAYING_TAB||" & playingTitle & "||" & playingURL & "||" & playingInfo
            \(pausedReturn)
            return "NOT_FOUND"
        end tell
        """

        guard let result = runAppleScript(script), result != "NOT_RUNNING", result != "NOT_FOUND" else {
            return nil
        }

        let parts = result.components(separatedBy: "||")
        guard parts.count >= 5 else { return nil }

        let rawTitle = parts[1]
        let url = parts[2]
        let playbackState = parts[3]
        let artworkURL = parts.count >= 7 ? parts[6] : ""

        var mediaCurrentTime: TimeInterval = 0
        var mediaDuration: TimeInterval = 0
        let mediaIsPlaying = playbackState == "PLAYING"

        mediaCurrentTime = TimeInterval(parts[4]) ?? 0
        if parts.count >= 6 {
            mediaDuration = TimeInterval(parts[5]) ?? 0
        }

        // Parse YouTube title format: "Song Name - Artist - YouTube"
        let parsed = parseYouTubeTitle(rawTitle)
        let chromeSourceName = chromeSourceName(for: url, fallback: target.displayName)

        return NowPlayingSnapshot(
            providerID: "browser",
            title: parsed.title,
            artist: parsed.artist,
            album: "",
            duration: mediaDuration,
            elapsedTime: mediaCurrentTime,
            playbackRate: mediaIsPlaying ? 1 : 0,
            isPlaying: mediaIsPlaying,
            sourceName: chromeSourceName,
            bundleIdentifier: target.id,
            albumArtist: "",
            artworkURL: artworkURL.isEmpty ? nil : artworkURL,
            trackIdentifier: url,
            isLocalFile: url.hasPrefix("file://"),
            browserTabURL: url,
            capturedAt: Date()
        )
    }

    private func applySnapshot(_ snapshot: NowPlayingSnapshot, stale: Bool = false) {
        guard isEnabled else { return }
        cancelPendingPublication()
        cancelModeConfirmation()
        shuffleMode = nil
        repeatMode = nil
        let incomingSignature = trackSignature(
            title: snapshot.title, artist: snapshot.artist, album: snapshot.album, bundleIdentifier: snapshot.bundleIdentifier
        ) + "||" + snapshot.trackIdentifier
        let retainedElapsed = stale && currentTrackSignature == incomingSignature
            ? projectedElapsedTime(at: Date()) : nil
        if currentTrackSignature != incomingSignature {
            cancelArtworkRequests()
            cancelSeek()
            albumArt = nil
        }
        if stale { cancelSeek() }
        currentChromeTabURL = snapshot.browserTabURL
        currentBundleIdentifier = snapshot.bundleIdentifier
        currentAlbumArtist = snapshot.albumArtist
        currentTrackIdentifier = snapshot.trackIdentifier
        currentTrackIsLocalFile = snapshot.isLocalFile
        currentArtworkURL = snapshot.artworkURL
        title = snapshot.title
        artist = snapshot.artist
        album = snapshot.album
        duration = snapshot.duration
        hasKnownPosition = snapshot.hasKnownPosition
        elapsedTime = retainedElapsed ?? PlaybackPosition(
            elapsed: snapshot.elapsedTime, capturedAt: snapshot.capturedAt,
            duration: snapshot.duration, rate: snapshot.playbackRate,
            isPlaying: snapshot.isPlaying && !stale
        ).elapsed(at: Date())
        playbackRate = snapshot.playbackRate
        isPlaying = stale ? false : snapshot.isPlaying
        sourceName = snapshot.sourceName
        providerStatus = stale ? .stale(snapshot.sourceName) : (snapshot.isPlaying ? .playing(snapshot.sourceName) : .paused(snapshot.sourceName))

        if snapshot.browserTabURL.isEmpty {
            lastPausedChromeTabURL = ""
        } else if !snapshot.isPlaying {
            lastPausedChromeTabURL = snapshot.browserTabURL
        }

        if snapshot.title != lastDetectedTitle {
            lastDetectedTitle = snapshot.title
            if snapshot.providerID == "browser" {
                albumArt = nil
            }
            if snapshot.isPlaying, !stale {
                self.onPlaybackAvailable?()
            }
        }

        if !stale {
            lastKnownSnapshot = snapshot
            confirmSeek(position: snapshot.hasKnownPosition ? elapsedTime : nil, sampledAt: snapshot.capturedAt)
        }

        updatePlaybackTimer()
    }

    private func fetchArtworkIfNeeded(for snapshot: NowPlayingSnapshot) {
        guard isEnabled else { return }
        switch snapshot.providerID {
        case "spotify":
            fetchSpotifyArtwork()
        case "browser":
            if let artworkURL = snapshot.artworkURL, !artworkURL.isEmpty {
                fetchRemoteArtwork(from: artworkURL)
            } else if snapshot.browserTabURL.contains("youtube.com") {
                fetchYouTubeThumbnail(from: snapshot.browserTabURL)
            }
        default:
            break
        }
    }

    private func rememberCurrentSnapshot(providerID: String) {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastKnownSnapshot = NowPlayingSnapshot(
            providerID: providerID,
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedTime: elapsedTime,
            playbackRate: playbackRate,
            isPlaying: isPlaying,
            sourceName: sourceName,
            bundleIdentifier: currentBundleIdentifier,
            albumArtist: currentAlbumArtist,
            artworkURL: currentArtworkURL,
            trackIdentifier: currentTrackIdentifier,
            isLocalFile: currentTrackIsLocalFile,
            browserTabURL: currentChromeTabURL,
            capturedAt: Date(),
            hasKnownPosition: hasKnownPosition
        )
    }

    @discardableResult
    private func showLastKnownSnapshotIfUseful() -> Bool {
        guard let snapshot = lastKnownSnapshot else { return false }
        guard snapshot.canRetainAsHistory(at: Date()) else { return false }
        if snapshot.providerID == "browser", !browserDetectionEnabled {
            return false
        }

        applySnapshot(snapshot, stale: true)
        return true
    }

    // MARK: - YouTube Helpers

    nonisolated private func parseYouTubeTitle(_ rawTitle: String) -> (title: String, artist: String) {
        // YouTube titles are typically: "Song Name - Artist - YouTube"
        // or "Song Name - YouTube"
        let cleaned = rawTitle
            .replacingOccurrences(of: " - YouTube Music", with: "")
            .replacingOccurrences(of: " - YouTube", with: "")
            .trimmingCharacters(in: .whitespaces)

        // Try to split on " - " to get artist and title
        let dashParts = cleaned.components(separatedBy: " - ")
        if dashParts.count >= 2 {
            // Could be "Artist - Song" or "Song - Artist"
            // YouTube Music usually does "Song - Artist"
            return (title: dashParts[0].trimmingCharacters(in: .whitespaces),
                    artist: dashParts[1...].joined(separator: " - ").trimmingCharacters(in: .whitespaces))
        }

        return (title: cleaned, artist: "")
    }

    private func fetchYouTubeThumbnail(from urlString: String) {
        // Extract video ID and fetch thumbnail
        guard let videoID = extractYouTubeVideoID(from: urlString) else { return }

        let thumbnailURL = "https://img.youtube.com/vi/\(videoID)/mqdefault.jpg"
        fetchRemoteArtwork(from: thumbnailURL)
    }

    private func cancelArtworkRequests() {
        artworkClearTask?.cancel()
        artworkClearTask = nil
        artworkLookupTask?.cancel()
        artworkLookupTask = nil
        artworkDownloadTask?.cancel()
        artworkDownloadTask = nil
        artworkRequestID = UUID()
    }

    private var currentTrackSignature: String {
        trackSignature(title: title, artist: artist, album: album, bundleIdentifier: currentBundleIdentifier)
            + "||" + currentTrackIdentifier
    }

    private func fetchRemoteArtwork(from urlString: String) {
        guard isEnabled, let url = URL(string: urlString) else { return }
        artworkDownloadTask?.cancel()
        let generation = lifecycleGeneration
        let requestID = UUID()
        artworkRequestID = requestID
        let signature = currentTrackSignature
        currentArtworkURL = urlString
        artworkDownloadTask = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let data, let image = NSImage(data: data) else { return }
            DispatchQueue.main.async {
                guard let self, self.isEnabled, self.lifecycleGeneration == generation,
                      self.artworkRequestID == requestID, self.currentTrackSignature == signature else { return }
                self.artworkDownloadTask = nil
                self.albumArt = image
            }
        }
        artworkDownloadTask?.resume()
    }

    nonisolated private func extractYouTubeVideoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "v" })?.value
    }

    // MARK: - AppleScript Runner

    nonisolated private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            // Don't log "application not running" errors as they're expected
            let errorNum = error[NSAppleScript.errorNumber] as? Int ?? 0
            if errorNum != -600 && errorNum != -1728 {
                print("[NowPlaying] AppleScript error: \(error)")
            }
            return nil
        }
        return result.stringValue
    }

    // MARK: - Playback Timer

    private func updatePlaybackTimer() {
        guard isEnabled else { return }
        ModuleRefreshScheduler.shared.unregister(playbackRefreshToken)
        playbackRefreshToken = nil
        lastPlaybackTickDate = nil

        if isPlaying, duration > 0, elapsedTime >= duration {
            calibrateAtTrackEnd()
        } else {
            endpointCalibrationKey = nil
        }
        guard hasKnownPosition, isPlaying, duration > 0, elapsedTime < duration else { return }

        lastPlaybackTickDate = Date()
        let generation = lifecycleGeneration
        playbackRefreshToken = ModuleRefreshScheduler.shared.register(
            id: "nowPlaying.progress",
            name: "Now Playing progress",
            module: .builtIn(.nowPlaying),
            policy: .presentationOnly(1, tolerance: 0.2),
            enabled: { [weak self] in
                self?.isEnabled == true && self?.isPlaying == true
            }
        ) { [weak self] in
            guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
            self.advancePlaybackProgress()
        }
    }

    private func projectedElapsedTime(at date: Date) -> TimeInterval {
        guard hasKnownPosition else { return 0 }
        guard duration > 0 else { return elapsedTime }
        return PlaybackPosition(
            elapsed: elapsedTime, capturedAt: lastPlaybackTickDate ?? date,
            duration: duration, rate: playbackRate, isPlaying: isPlaying
        ).elapsed(at: date)
    }

    private func advancePlaybackProgress() {
        guard isEnabled else { return }
        guard hasKnownPosition, isPlaying, duration > 0 else {
            updatePlaybackTimer()
            return
        }

        let now = Date()
        elapsedTime = projectedElapsedTime(at: now)
        lastPlaybackTickDate = now
        if elapsedTime >= duration {
            elapsedTime = duration
            updatePlaybackTimer()
        }
    }

    // MARK: - Playback Controls

    func togglePlayPause() {
        guard isEnabled, canControlPlayback else { return }
        cancelSeek()
        if sourceName == "Spotify", !isApplicationRunning("Spotify") {
            refreshPreferredSource()
            return
        }

        if sourceName == "Apple Music", !isApplicationRunning("Music") {
            refreshPreferredSource()
            return
        }

        advancePlaybackProgress()
        let shouldPlay = !isPlaying
        publication.expectPlayback(shouldPlay, at: Date())

        // Browser playback is checked first because the MediaRemote command
        // path doesn't reliably control browser-tab <video>/<audio> elements
        // even when Chrome's MediaSession registers with MediaRemote. JS
        // injection talks to the element directly.
        if isBrowserPlaybackSource {
            if controlChromePlayback(shouldPlay: shouldPlay) {
                refreshPlaybackStateAfterControlAction(preferChromeRefresh: true)
                return
            }
            // Fall through to MR/AppleScript if JS injection failed (e.g.
            // Chrome "Allow JavaScript from Apple Events" disabled).
        }

        if shouldUseMediaRemoteControls {
            sendAdapterControl(["send", String(shouldPlay ? kMRPlay : kMRPause)])
            return
        }

        // Fallback to AppleScript
        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to \(shouldPlay ? "play" : "pause")")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to \(shouldPlay ? "play" : "pause")")
        default:
            _ = sendCommandFunc?(shouldPlay ? kMRPlay : kMRPause, nil)
        }

        refreshPlaybackStateAfterControlAction()
    }

    func nextTrack() {
        guard isEnabled, canControlPlayback else { return }
        publication.expectTrackChange(at: Date())
        schedulePublication(generation: lifecycleGeneration)
        cancelSeek()
        if shouldUseMediaRemoteControls {
            sendAdapterControl(["send", String(kMRNextTrack)])
            return
        }
        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to next track")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to next track")
        default:
            _ = sendCommandFunc?(kMRNextTrack, nil)
        }
        refreshPlaybackStateAfterControlAction()
    }

    func previousTrack() {
        guard isEnabled, canControlPlayback else { return }
        publication.expectTrackChange(at: Date())
        schedulePublication(generation: lifecycleGeneration)
        cancelSeek()
        if shouldUseMediaRemoteControls {
            sendAdapterControl(["send", String(kMRPreviousTrack)])
            return
        }
        switch sourceName {
        case "Spotify":
            _ = runAppleScript("tell application \"Spotify\" to previous track")
        case "Apple Music":
            _ = runAppleScript("tell application \"Music\" to previous track")
        default:
            _ = sendCommandFunc?(kMRPreviousTrack, nil)
        }
        refreshPlaybackStateAfterControlAction()
    }

    func skipTrack(forward: Bool) {
        if forward { nextTrack() } else { previousTrack() }
    }

    func seek(to time: TimeInterval) {
        guard isEnabled, canSeek, !isControlPending, !isPresentationPending else { return }
        guard time.isFinite else { return }
        cancelSeek()
        let request = PendingPlaybackSeek(trackID: presentationTrackID, target: max(0, min(time, duration)),
                                          requestedAt: Date(), duration: duration, rate: playbackRate, isPlaying: isPlaying)
        pendingSeek = request
        controlError = ""
        let generation = lifecycleGeneration
        let useMediaRemote = shouldUseMediaRemoteControls
        let player = sourceName
        seekTask = Task { [weak self] in
            guard let self, self.isCurrentSeek(request, generation: generation) else { return }
            do {
                if useMediaRemote {
                    // This symbol was already loaded for transport controls. Its
                    // contract is void(seconds); old adapter builds incorrectly
                    // interpreted its return value as command success/failure.
                    if let setElapsedTime = self.setElapsedTimeFunc {
                        setElapsedTime(request.target)
                    } else if let resources = self.mediaRemoteAdapterResources() {
                        let micros = Int64(min(request.target * 1_000_000, Double(Int64.max - 1024)))
                        _ = try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/perl"),
                            arguments: [resources.scriptURL.path, resources.frameworkURL.path, "seek", String(micros)])
                    } else {
                        throw NowPlayingProviderError.unsupported
                    }
                } else {
                    let application = player == "Spotify" ? "Spotify" : "Music"
                    let result = await self.runOnAppleScriptQueue {
                        self.runAppleScript("tell application \"\(application)\" to set player position to \(request.target)\nreturn \"OK\"")
                    }
                    guard result == "OK" else { throw NowPlayingProviderError.unsupported }
                }
                // Bounded readback, never a permanent polling loop. Stream
                // updates may confirm the request before any read completes.
                for delay in [150, 350, 700, 1000, 800] {
                    guard self.isCurrentSeek(request, generation: generation) else { return }
                    if useMediaRemote { self.requestAdapterCalibration() }
                    else { self.refreshPreferredSource() }
                    try await Task.sleep(for: .milliseconds(delay))
                }
                guard self.isCurrentSeek(request, generation: generation) else { return }
                self.pendingSeek = nil
                self.seekTask = nil
                self.controlError = L10n.text("The player did not confirm the new position.")
            } catch {
                guard self.isCurrentSeek(request, generation: generation) else { return }
                self.pendingSeek = nil
                self.seekTask = nil
                self.controlError = L10n.text("Unable to change playback position. Please try again.")
            }
        }
    }

    private func isCurrentSeek(_ request: PendingPlaybackSeek, generation: UUID) -> Bool {
        isEnabled && lifecycleGeneration == generation && !Task.isCancelled &&
            pendingSeek?.id == request.id && presentationTrackID == request.trackID
    }

    private func confirmSeek(position: TimeInterval?, sampledAt: Date?) {
        guard let pendingSeek,
              pendingSeek.accepts(position: position, trackID: presentationTrackID, sampledAt: sampledAt, now: Date()) else { return }
        cancelSeek()
        controlError = ""
    }

    private func cancelSeek() {
        seekTask?.cancel()
        seekTask = nil
        pendingSeek = nil
    }

    func toggleShuffle() {
        guard canChangePlaybackMode, let shuffleMode else { return }
        let command = PlaybackModeCommand.shuffle(shuffleMode.toggled)
        sendAdapterControl(command.arguments, confirming: command)
    }

    func cycleRepeatMode() {
        guard canChangePlaybackMode, let repeatMode else { return }
        let command = PlaybackModeCommand.repeatMode(repeatMode.next)
        sendAdapterControl(command.arguments, confirming: command)
    }

    func openCurrentPlayer(fromIsland appState: AppState) {
        guard canOpenCurrentPlayer else { return }
        let source = currentBundleIdentifier
        guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: source) else {
            controlError = L10n.text("Unable to open the current player.")
            return
        }
        let generation = lifecycleGeneration
        appState.openExternalApplication(at: applicationURL, for: .nowPlaying, isCurrent: { [weak self] in
            self?.isEnabled == true && self?.lifecycleGeneration == generation && self?.currentBundleIdentifier == source
        }, completion: { [weak self] succeeded in
            if !succeeded { self?.controlError = L10n.text("Unable to open the current player.") }
        })
    }

    // MARK: - Helpers

    var formattedElapsedTime: String {
        hasKnownPosition || isSeeking ? formatTime(displayedElapsedTime) : "—:—"
    }

    var formattedDuration: String {
        formatTime(duration)
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return displayedElapsedTime / duration
    }

    var browserTargets: [NowPlayingBrowserTarget] {
        nowPlayingSupportedBrowserTargets
    }

    var emptyTitle: String {
        providerStatus.title
    }

    var emptySubtitle: String {
        providerStatus.subtitle
    }

    func isBrowserAllowed(_ browserID: String) -> Bool {
        allowedBrowserBundleIDs.contains(browserID)
    }

    func setBrowser(_ browserID: String, allowed: Bool) {
        var nextAllowed = allowedBrowserBundleIDs
        if allowed {
            nextAllowed.insert(browserID)
        } else {
            nextAllowed.remove(browserID)
        }
        allowedBrowserBundleIDs = nextAllowed
    }

    func testBrowserDetection() {
        guard isEnabled else { return }
        browserDetectionTask?.cancel()
        browserDetectionTestMessage = L10n.text("Checking browser media...")
        guard browserDetectionEnabled else {
            providerStatus = .browserDisabled
            browserDetectionTestMessage = L10n.text("Enable browser media detection first.")
            return
        }

        let generation = lifecycleGeneration
        browserDetectionTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let snapshot = await self.runOnAppleScriptQueue {
                self.browserSnapshotViaAppleScript(allowPausedFallback: true)
            }
            guard self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled else { return }

            guard let snapshot else {
                self.providerStatus = .permissionNeeded("Browser media")
                self.browserDetectionTestMessage = L10n.text("No browser media found. Check Automation permission and browser JavaScript from Apple Events.")
                return
            }

            self.applySnapshot(snapshot)
            self.fetchArtworkIfNeeded(for: snapshot)
            self.browserDetectionTestMessage = snapshot.isPlaying
                ? L10n.format("Detected media in %@.", snapshot.sourceName)
                : L10n.format("Detected paused media in %@.", snapshot.sourceName)
        }
    }

    func openAutomationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else { return }
        NSWorkspace.shared.open(url)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var isBrowserPlaybackSource: Bool {
        switch sourceName {
        case "YouTube", "YouTube Music", "SoundCloud", "Spotify Web", "Google Chrome", "Google Chrome Canary":
            return true
        default:
            return !currentChromeTabURL.isEmpty && !lastPausedChromeTabURL.isEmpty
        }
    }

    private func refreshPlaybackStateAfterControlAction(preferChromeRefresh: Bool = false) {
        guard isEnabled else { return }
        controlRefreshTask?.cancel()
        let generation = lifecycleGeneration
        controlRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch { return }
            guard let self, self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled else { return }
            if preferChromeRefresh {
                await self.fetchChromeViaAppleScript()
                return
            }
            if self.shouldUseMediaRemoteControls, self.adapterProcess?.isRunning == true { self.requestAdapterCalibration() }
            else { self.refreshPreferredSource() }
        }
    }

    private func controlChromePlayback(shouldPlay: Bool) -> Bool {
        let target = browserTarget(for: currentBundleIdentifier) ?? browserTargets.first
        guard let target else { return false }
        let preferredURL = shouldPlay ? lastPausedChromeTabURL : currentChromeTabURL
        let js = chromeControlJavaScript(shouldPlay: shouldPlay)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPreferredURL = escapeAppleScriptString(preferredURL)
        let processName = escapeAppleScriptString(target.processName)
        let applicationName = escapeAppleScriptString(target.applicationName)

        let script = """
        tell application "System Events"
            if not (exists process "\(processName)") then return "NOT_RUNNING"
        end tell
        tell application "\(applicationName)"
            set preferredURL to "\(escapedPreferredURL)"
            if preferredURL is not "" then
                repeat with w in windows
                    repeat with t in tabs of w
                        if (URL of t) is preferredURL then
                            try
                                set actionResult to execute t javascript "\(js)"
                                if actionResult is "OK" then return "OK||" & (URL of t)
                            end try
                        end if
                    end repeat
                end repeat
            end if
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set actionResult to execute t javascript "\(js)"
                        if actionResult is "OK" then return "OK||" & (URL of t)
                    end try
                end repeat
            end repeat
            return "NO_MEDIA"
        end tell
        """

        guard let result = runAppleScript(script), result.hasPrefix("OK||") else {
            return false
        }

        let actedURL = String(result.dropFirst(4))
        currentChromeTabURL = actedURL
        if shouldPlay {
            if lastPausedChromeTabURL == actedURL {
                lastPausedChromeTabURL = ""
            }
        } else {
            lastPausedChromeTabURL = actedURL
        }
        return true
    }

    private func browserTarget(for bundleIdentifier: String) -> NowPlayingBrowserTarget? {
        nowPlayingSupportedBrowserTargets.first { $0.id == bundleIdentifier }
    }

    private func chromeControlJavaScript(shouldPlay: Bool) -> String {
        if shouldPlay {
            return """
            (function() {
                var media = Array.from(document.querySelectorAll('video,audio'));
                if (!media.length) return 'NO_MEDIA';
                var target = media.find(function(item) { return item.paused && !item.ended; }) || media.find(function(item) { return !item.ended; }) || media[0];
                if (!target) return 'NO_MEDIA';
                try {
                    target.play();
                    return 'OK';
                } catch (error) {
                    return 'ERROR';
                }
            })();
            """
        }

        return """
        (function() {
            var media = Array.from(document.querySelectorAll('video,audio'));
            if (!media.length) return 'NO_MEDIA';
            var handled = false;
            media.forEach(function(item) {
                if (!item.paused && !item.ended) {
                    item.pause();
                    handled = true;
                }
            });
            return handled ? 'OK' : 'NO_MATCH';
        })();
        """
    }

    nonisolated private func chromeSourceName(for url: String, fallback: String = "Google Chrome") -> String {
        if url.contains("music.youtube.com") { return "YouTube Music" }
        if url.contains("youtube.com") { return "YouTube" }
        if url.contains("soundcloud.com") { return "SoundCloud" }
        if url.contains("spotify.com") { return "Spotify Web" }
        return fallback
    }

    private func sourceName(forBundleIdentifier bundleIdentifier: String) -> String {
        switch bundleIdentifier {
        case "com.netease.163music":
            return L10n.text("NetEase Cloud Music")
        case "com.apple.Music":
            return "Apple Music"
        case "com.spotify.client":
            return "Spotify"
        case "com.google.Chrome":
            return "Google Chrome"
        case "com.google.Chrome.canary":
            return "Google Chrome Canary"
        case "com.apple.Safari":
            return "Safari"
        case "com.microsoft.edgemac":
            return "Microsoft Edge"
        default:
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
               let bundle = Bundle(url: appURL),
               let appName = bundle.object(forInfoDictionaryKey: "CFBundleName") as? String,
               !appName.isEmpty {
                return appName
            }
            return bundleIdentifier
        }
    }

    func normalizedSnapshot() -> [String: Any]? {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSource = sourceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBundleIdentifier = currentBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedArtworkURL = normalizedArtworkSnapshotURL()

        guard !normalizedTitle.isEmpty else { return nil }
        guard !normalizedArtist.isEmpty else { return nil }

        return [
            "sourceApp": normalizedSource.isEmpty ? (normalizedBundleIdentifier.isEmpty ? "Unknown" : sourceName(forBundleIdentifier: normalizedBundleIdentifier)) : normalizedSource,
            "bundleIdentifier": normalizedBundleIdentifier.isEmpty ? NSNull() : normalizedBundleIdentifier,
            "title": normalizedTitle,
            "artist": normalizedArtist,
            "album": album.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : album,
            "albumArtist": currentAlbumArtist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : currentAlbumArtist,
            "durationSeconds": duration > 0 ? duration : NSNull(),
            "elapsedSeconds": hasKnownPosition ? projectedElapsedTime(at: Date()) : NSNull(),
            "artworkURL": resolvedArtworkURL ?? NSNull(),
            "playbackState": isPlaying ? "playing" : "paused",
            "trackIdentifier": currentTrackIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? NSNull() : currentTrackIdentifier,
            "isLocalFile": currentTrackIsLocalFile,
            "capturedAtEpochMs": Int(Date().timeIntervalSince1970 * 1000)
        ]
    }

    var sourceAppIcon: NSImage? {
        guard !currentBundleIdentifier.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: currentBundleIdentifier) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        icon.size = NSSize(width: 24, height: 24)
        return icon
    }

    private func trackSignature(title: String, artist: String, album: String, bundleIdentifier: String) -> String {
        [bundleIdentifier, title, artist, album]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "||")
    }

    private func clampElapsedTime(_ elapsedTime: TimeInterval, duration: TimeInterval) -> TimeInterval {
        let normalizedElapsedTime = max(0, elapsedTime)
        guard duration > 0 else {
            return normalizedElapsedTime
        }
        return min(normalizedElapsedTime, duration)
    }

    private func normalizedArtworkSnapshotURL() -> String? {
        if let currentArtworkURL, currentArtworkURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            return currentArtworkURL
        }

        guard let albumArt,
              let tiffData = albumArt.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return "data:image/png;base64," + pngData.base64EncodedString()
    }

    private func isChromeBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier == "com.google.Chrome" || bundleIdentifier == "com.google.Chrome.canary"
    }

    nonisolated private func escapeAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func isApplicationRunning(_ name: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            app.localizedName == name && !app.isTerminated
        }
    }

    nonisolated private func isApplicationInstalled(bundleIdentifier: String) -> Bool {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return false
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func clearCurrentTrack() {
        cancelPendingPublication()
        artworkDecoder = PlaybackArtworkDecoder()
        defer {
            compactPlaybackGraceTask?.cancel()
            compactPlaybackGraceTask = nil
            compactPlaybackGrace.clear()
            pausedPlaybackRetention = PausedPlaybackRetention()
        }
        cancelArtworkRequests()
        cancelModeConfirmation()
        cancelSeek()
        adapterPositionAnchor = nil
        lastKnownSnapshot = nil
        mediaRemoteActive = false
        title = ""
        artist = ""
        album = ""
        albumArt = nil
        albumArtColor = nil
        isPlaying = false
        duration = 0
        elapsedTime = 0
        hasKnownPosition = false
        shuffleMode = nil
        repeatMode = nil
        playbackRate = 0
        sourceName = ""
        currentAlbumArtist = ""
        currentArtworkURL = nil
        currentTrackIdentifier = ""
        currentTrackIsLocalFile = false
        currentChromeTabURL = ""
        lastPausedChromeTabURL = ""
        currentBundleIdentifier = ""
        lastDetectedTitle = ""
        providerStatus = browserDetectionEnabled ? .idle : .browserDisabled
        ModuleRefreshScheduler.shared.unregister(playbackRefreshToken)
        playbackRefreshToken = nil
        lastPlaybackTickDate = nil
    }

    deinit {
        providerRefreshTask?.cancel()
        browserDetectionTask?.cancel()
        controlRefreshTask?.cancel()
        artworkLookupTask?.cancel()
        artworkDownloadTask?.cancel()
        adapterStartupTask?.cancel()
        adapterRestartTask?.cancel()
        adapterReadTask?.cancel()
        adapterControlTask?.cancel()
        modeConfirmationTask?.cancel()
        seekTask?.cancel()
        for cancel in pendingAppleScriptJobs.values { cancel() }
        let sourceToken = sourceRefreshToken
        let playbackToken = playbackRefreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(sourceToken)
            ModuleRefreshScheduler.shared.unregister(playbackToken)
        }
        adapterStreamTask?.cancel()
        if let adapterPipeHandler {
            Task {
                await adapterPipeHandler.close()
            }
        }
        if let adapterProcess { AdapterProcessRunner.stopOwnedProcess(adapterProcess) }
        if let handle {
            dlclose(handle)
        }
    }
}

/// Preserve the displayed image identity across repeated full media snapshots.
/// Keeping this at the decode boundary also avoids repeated image decompression.
struct PlaybackArtworkDecoder {
    private var encodedData: String?
    private var image: NSImage?

    mutating func decode(_ value: String?) -> NSImage? {
        guard value != encodedData else { return image }
        encodedData = value
        image = value.flatMap {
            Data(base64Encoded: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }.flatMap { NSImage(data: $0) }
        return image
    }
}
