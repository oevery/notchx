import Foundation

struct NowPlayingUpdate: Decodable {
    let payload: NowPlayingPayload
    let diff: Bool?
    var type: String? = nil
}

// Keep this value model Foundation-only so portable checks exercise the shipping
// decoder and merge. Contract: https://github.com/ungive/mediaremote-adapter#stream
struct NowPlayingPayload: Decodable {
    private(set) var title: String?
    private(set) var artist: String?
    private(set) var album: String?
    private(set) var albumArtist: String?
    private(set) var duration: Double?
    private(set) var elapsedTime: Double?
    private(set) var artworkData: String?
    private(set) var timestamp: String?
    private(set) var playbackRate: Double?
    private(set) var playing: Bool?
    private(set) var uniqueIdentifier: String?
    private(set) var contentItemIdentifier: String?
    private(set) var trackIdentifier: String?
    private(set) var isLocalFile: Bool?
    private(set) var parentApplicationBundleIdentifier: String?
    private(set) var bundleIdentifier: String?
    private(set) var shuffleMode: PlaybackShuffleMode?
    private(set) var repeatMode: PlaybackRepeatMode?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case title, artist, album, albumArtist, duration, elapsedTime, artworkData, timestamp, playbackRate, playing, uniqueIdentifier, contentItemIdentifier, trackIdentifier, isLocalFile, parentApplicationBundleIdentifier, bundleIdentifier, shuffleMode, repeatMode
    }
    private var presentFields: Set<CodingKeys>

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        presentFields = Set(container.allKeys)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist)
        album = try container.decodeIfPresent(String.self, forKey: .album)
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration)
        elapsedTime = try container.decodeIfPresent(Double.self, forKey: .elapsedTime)
        artworkData = try container.decodeIfPresent(String.self, forKey: .artworkData)
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp)
        playbackRate = try container.decodeIfPresent(Double.self, forKey: .playbackRate)
        playing = try container.decodeIfPresent(Bool.self, forKey: .playing)
        uniqueIdentifier = try Self.decodeIdentifier(container, key: .uniqueIdentifier)
        contentItemIdentifier = try Self.decodeIdentifier(container, key: .contentItemIdentifier)
        trackIdentifier = try container.decodeIfPresent(String.self, forKey: .trackIdentifier)
        isLocalFile = try container.decodeIfPresent(Bool.self, forKey: .isLocalFile)
        parentApplicationBundleIdentifier = try container.decodeIfPresent(String.self, forKey: .parentApplicationBundleIdentifier)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        shuffleMode = (try? container.decode(Int.self, forKey: .shuffleMode)).flatMap(PlaybackShuffleMode.init(rawValue:))
        repeatMode = (try? container.decode(Int.self, forKey: .repeatMode)).flatMap(PlaybackRepeatMode.init(rawValue:))
    }

    var sourceBundleIdentifier: String {
        [parentApplicationBundleIdentifier, bundleIdentifier].compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? ""
    }

    var stableIdentifier: String {
        // NetEase rotates its MediaRemote content-item UUID on transport changes,
        // before publishing the next song. It is not a song identifier.
        let identifiers = sourceBundleIdentifier == "com.netease.163music"
            ? [uniqueIdentifier, trackIdentifier]
            : [uniqueIdentifier, contentItemIdentifier, trackIdentifier]
        return identifiers.compactMap { $0 }.first { !$0.isEmpty } ?? ""
    }

    func isSameTrack(as other: Self) -> Bool {
        guard sourceBundleIdentifier == other.sourceBundleIdentifier else { return false }
        if !stableIdentifier.isEmpty, !other.stableIdentifier.isEmpty { return stableIdentifier == other.stableIdentifier && title == other.title }
        return title == other.title && artist == other.artist && album == other.album
    }

    var timestampDate: Date? {
        guard let timestamp else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: timestamp) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: timestamp)
    }

    func calibratedElapsedTime(incoming: Self, previous: Self? = nil, diff: Bool,
                               previousElapsed: TimeInterval?, trackChanged: Bool, now: Date) -> TimeInterval? {
        // A missing position is unknown, not the beginning of the track. A
        // timestamp-only diff must never re-anchor an old position to a new date.
        if incoming.contains(.elapsedTime) && incoming.elapsedTime == nil { return nil }
        guard let position = incoming.elapsedTime else {
            return trackChanged ? nil : previousElapsed.map(clampedPosition)
        }
        guard position.isFinite, position >= 0 else { return nil }

        // Full reads after controls often repeat the same source anchor. In
        // particular, pausing must not reinterpret that old anchor at rate zero.
        if !trackChanged, let previousElapsed, let previous,
           position == previous.elapsedTime, incoming.timestamp != nil,
           incoming.timestamp == previous.timestamp {
            return clampedPosition(previousElapsed)
        }
        let rate = playbackRate ?? 1
        let delta = max(0, now.timeIntervalSince(incoming.timestampDate ?? now))
        let projected = position + ((playing ?? false) && rate.isFinite ? delta * max(0, rate) : 0)
        return clampedPosition(projected)
    }

    private func clampedPosition(_ position: TimeInterval) -> TimeInterval {
        guard let duration, duration.isFinite, duration > 0 else { return max(0, position) }
        return min(duration, max(0, position))
    }

    private static func decodeIdentifier(_ container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> String? {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) { return nil }
        if let value = try? container.decode(String.self, forKey: key) { return value }
        if let value = try? container.decode(Int64.self, forKey: key) { return String(value) }
        return nil
    }

    func contains(_ key: CodingKeys) -> Bool { presentFields.contains(key) }

    func applying(to previous: Self?, diff: Bool) -> Self {
        guard diff, let previous else { return self }
        var result = previous
        if contains(.title) { result.title = title }
        if contains(.artist) { result.artist = artist }
        if contains(.album) { result.album = album }
        if contains(.albumArtist) { result.albumArtist = albumArtist }
        if contains(.duration) { result.duration = duration }
        if contains(.elapsedTime) { result.elapsedTime = elapsedTime }
        if contains(.artworkData) { result.artworkData = artworkData }
        if contains(.timestamp) { result.timestamp = timestamp }
        if contains(.playbackRate) { result.playbackRate = playbackRate }
        if contains(.playing) { result.playing = playing }
        if contains(.uniqueIdentifier) { result.uniqueIdentifier = uniqueIdentifier }
        if contains(.contentItemIdentifier) { result.contentItemIdentifier = contentItemIdentifier }
        if contains(.trackIdentifier) { result.trackIdentifier = trackIdentifier }
        if contains(.isLocalFile) { result.isLocalFile = isLocalFile }
        if contains(.parentApplicationBundleIdentifier) { result.parentApplicationBundleIdentifier = parentApplicationBundleIdentifier }
        if contains(.bundleIdentifier) { result.bundleIdentifier = bundleIdentifier }
        if contains(.shuffleMode) { result.shuffleMode = shuffleMode }
        if contains(.repeatMode) { result.repeatMode = repeatMode }
        // Track metadata and artwork can arrive in separate diffs. Never tag
        // the previous song's bytes as the new song's artwork.
        if !contains(.artworkData), !result.isSameTrack(as: previous) {
            result.artworkData = nil
        }
        result.presentFields.formUnion(presentFields)
        return result
    }
}

// Values are the adapter's MRAShuffleMode/MRARepeatMode wire contract, not
// MPShuffleType/MPRepeatType. Missing, zero and future values remain unknown.
enum PlaybackShuffleMode: Int {
    case off = 1, albums = 2, tracks = 3
    var toggled: Self { self == .off ? .tracks : .off }
}

enum PlaybackRepeatMode: Int {
    case off = 1, track = 2, playlist = 3
    var next: Self {
        switch self {
        case .off: return .playlist
        case .playlist: return .track
        case .track: return .off
        }
    }
}

enum PlaybackModeCommand: Equatable {
    case shuffle(PlaybackShuffleMode)
    case repeatMode(PlaybackRepeatMode)

    var arguments: [String] {
        switch self {
        case .shuffle(let mode): return ["shuffle", String(mode.rawValue)]
        case .repeatMode(let mode): return ["repeat", String(mode.rawValue)]
        }
    }

    func isConfirmed(shuffle: PlaybackShuffleMode?, repeatMode: PlaybackRepeatMode?) -> Bool {
        switch self {
        case .shuffle(let expected): return shuffle == expected
        case .repeatMode(let expected): return repeatMode == expected
        }
    }
}

/// NetEase emits transport pauses and partially replaced full snapshots while
/// loading a song. Only stable presentation snapshots cross this boundary.
struct NetEasePlaybackPublication {
    private(set) var published: NowPlayingPayload?
    private(set) var pending: NowPlayingPayload?
    private(set) var deadline: Date?
    private var trackChangeHoldUntil: Date?
    private var playbackIntent: (playing: Bool, expires: Date)?

    mutating func cancelPlaybackIntent() { playbackIntent = nil }

    mutating func expectTrackChange(at now: Date) {
        playbackIntent = nil
        trackChangeHoldUntil = now.addingTimeInterval(2)
        if published?.playing == true, pending?.playing == false, let deadline {
            self.deadline = max(deadline, now.addingTimeInterval(2))
        }
    }

    mutating func expectPlayback(_ playing: Bool, at now: Date) {
        playbackIntent = (playing, now.addingTimeInterval(2))
        trackChangeHoldUntil = nil
    }

    mutating func receive(_ payload: NowPlayingPayload, at now: Date) -> NowPlayingPayload? {
        guard payload.sourceBundleIdentifier == "com.netease.163music",
              let published, published.sourceBundleIdentifier == payload.sourceBundleIdentifier,
              !(payload.title ?? "").isEmpty else {
            return commit(payload)
        }
        if let intent = playbackIntent, intent.expires < now { playbackIntent = nil }
        let metadataChanged = !payload.hasSamePresentationMetadata(as: published)
        let confirmedIntent = playbackIntent.map { $0.playing == payload.playing } ?? false
        if !metadataChanged && (confirmedIntent || payload.playing == published.playing || payload.playing == true) {
            if confirmedIntent { playbackIntent = nil }
            return commit(payload)
        }
        let candidateChanged = pending.map {
            !$0.hasSamePresentationMetadata(as: payload) || $0.playing != payload.playing
        } ?? true
        pending = payload
        if candidateChanged {
            let loadingPause = published.playing == true && payload.playing == false && !confirmedIntent
            let quietPeriod = loadingPause ? 0.65 : 0.5
            let quietDeadline = now.addingTimeInterval(quietPeriod)
            deadline = loadingPause ? max(quietDeadline, trackChangeHoldUntil ?? quietDeadline) : quietDeadline
        } else if confirmedIntent, let deadline {
            // New feedback confirming a local command releases an earlier skip hold.
            self.deadline = min(deadline, now.addingTimeInterval(0.5))
        }
        return flush(at: now)
    }

    mutating func flush(at now: Date) -> NowPlayingPayload? {
        guard let deadline, now >= deadline, let pending else { return nil }
        return commit(pending)
    }

    mutating func reset() { self = Self() }

    private mutating func commit(_ payload: NowPlayingPayload) -> NowPlayingPayload {
        if published?.sourceBundleIdentifier != payload.sourceBundleIdentifier {
            playbackIntent = nil
            trackChangeHoldUntil = nil
        }
        if playbackIntent?.playing == payload.playing { playbackIntent = nil }
        published = payload
        pending = nil
        deadline = nil

        return payload
    }
}

private extension NowPlayingPayload {
    func hasSamePresentationMetadata(as other: Self) -> Bool {
        sourceBundleIdentifier == other.sourceBundleIdentifier && stableIdentifier == other.stableIdentifier &&
        title == other.title && artist == other.artist && album == other.album &&
        albumArtist == other.albumArtist && duration == other.duration && artworkData == other.artworkData
    }
}
