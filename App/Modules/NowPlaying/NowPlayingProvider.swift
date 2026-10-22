import Foundation

struct NowPlayingSnapshot {
    let providerID: String
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let elapsedTime: TimeInterval
    let playbackRate: Double
    let isPlaying: Bool
    let sourceName: String
    let bundleIdentifier: String
    let albumArtist: String
    let artworkURL: String?
    let trackIdentifier: String
    let isLocalFile: Bool
    let browserTabURL: String
    let capturedAt: Date
    var hasKnownPosition: Bool = true

    func canRetainAsHistory(at date: Date) -> Bool {
        let age = date.timeIntervalSince(capturedAt)
        return (0..<600).contains(age) && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

enum NowPlayingProviderStatus: Equatable {
    case idle
    case checking(String)
    case playing(String)
    case paused(String)
    case stale(String)
    case browserDisabled
    case permissionNeeded(String)
    case unavailable(String)

    var isLivePlayback: Bool {
        if case .playing = self { return true }
        return false
    }

    var canControlPlayback: Bool {
        switch self {
        case .playing, .paused: return true
        default: return false
        }
    }

    var isHistory: Bool {
        if case .stale = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .idle:
            return L10n.text("Nothing is playing")
        case .checking(let source):
            return L10n.format("Checking %@", source)
        case .playing(let source):
            return source
        case .paused(let source):
            return L10n.format("%@ paused", source)
        case .stale(let source):
            return L10n.format("%@ last played", source)
        case .browserDisabled:
            return L10n.text("Browser detection is off")
        case .permissionNeeded(let source):
            return L10n.format("%@ needs permission", source)
        case .unavailable(let source):
            return L10n.format("%@ unavailable", source)
        }
    }

    var subtitle: String {
        switch self {
        case .idle:
            return L10n.text("Start playback to pin controls here.")
        case .checking:
            return L10n.text("Looking for active media.")
        case .playing:
            return L10n.text("Playback controls are ready.")
        case .paused:
            return L10n.text("Resume playback when you are ready.")
        case .stale:
            return L10n.text("The last known track is kept here briefly.")
        case .browserDisabled:
            return L10n.text("Enable browser media detection for Chrome playback.")
        case .permissionNeeded:
            return L10n.text("Allow automation access and browser JavaScript from Apple Events.")
        case .unavailable:
            return L10n.text("Open the app and start playback, then try again.")
        }
    }
}

struct NowPlayingBrowserTarget: Identifiable, Equatable {
    let id: String
    let displayName: String
    let applicationName: String
    let processName: String
}

enum NowPlayingProviderError: Error {
    case unsupported
}

@MainActor
protocol NowPlayingProvider {
    var id: String { get }
    var displayName: String { get }
    var requiresPermission: Bool { get }
    func currentSnapshot() async -> NowPlayingSnapshot?
    func playPause() async throws
    func nextTrack() async throws
    func previousTrack() async throws
}

@MainActor
struct NowPlayingScriptProvider: NowPlayingProvider {
    let id: String
    let displayName: String
    let requiresPermission: Bool
    let currentSnapshotHandler: () async -> NowPlayingSnapshot?
    let playPauseHandler: () async throws -> Void
    let nextTrackHandler: () async throws -> Void
    let previousTrackHandler: () async throws -> Void

    init(
        id: String,
        displayName: String,
        requiresPermission: Bool,
        currentSnapshot: @escaping () async -> NowPlayingSnapshot?,
        playPause: @escaping () async throws -> Void = { throw NowPlayingProviderError.unsupported },
        nextTrack: @escaping () async throws -> Void = { throw NowPlayingProviderError.unsupported },
        previousTrack: @escaping () async throws -> Void = { throw NowPlayingProviderError.unsupported }
    ) {
        self.id = id
        self.displayName = displayName
        self.requiresPermission = requiresPermission
        self.currentSnapshotHandler = currentSnapshot
        self.playPauseHandler = playPause
        self.nextTrackHandler = nextTrack
        self.previousTrackHandler = previousTrack
    }

    func currentSnapshot() async -> NowPlayingSnapshot? {
        await currentSnapshotHandler()
    }

    func playPause() async throws {
        try await playPauseHandler()
    }

    func nextTrack() async throws {
        try await nextTrackHandler()
    }

    func previousTrack() async throws {
        try await previousTrackHandler()
    }
}
