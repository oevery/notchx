import Foundation

/// Project a provider position without polling the player or losing time while hidden.
struct PlaybackPosition {
    let elapsed: TimeInterval
    let capturedAt: Date

    let duration: TimeInterval
    let rate: Double
    let isPlaying: Bool

    func elapsed(at date: Date) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        let position = elapsed.isFinite ? max(0, elapsed) : 0
        let delta = max(0, date.timeIntervalSince(capturedAt))
        let speed = rate.isFinite ? max(0, rate) : 0
        return min(duration, position + (isPlaying ? delta * speed : 0))
    }
}

/// A requested position is a UI preview until the same track reports it back.
/// Never write this value into the provider's authoritative playback timeline.
struct PendingPlaybackSeek {
    let id = UUID()
    let trackID: String
    let target: TimeInterval
    let requestedAt: Date
    let duration: TimeInterval
    let rate: Double
    let isPlaying: Bool

    func position(at date: Date) -> TimeInterval {
        PlaybackPosition(elapsed: target, capturedAt: requestedAt, duration: duration,
                         rate: rate, isPlaying: isPlaying).elapsed(at: date)
    }

    func accepts(position: TimeInterval?, trackID: String, sampledAt: Date?, now: Date) -> Bool {
        guard self.trackID == trackID, let position, position.isFinite else { return false }
        if let sampledAt, sampledAt < requestedAt.addingTimeInterval(-0.25) { return false }
        // Players may quantize positions or sample before delivery. Allow that
        // latency without treating unrelated old positions as acknowledgement.
        return position >= target - 1.5 && position <= self.position(at: now) + 1.5
    }
}

/// Keep brief pause/loading events from bouncing the compact surface through
/// an unrelated idle module. This never changes authoritative playback state.
struct CompactPlaybackGrace {
    private(set) var deadline: Date?
    mutating func update(wasPlaying: Bool, isPlaying: Bool, enabled: Bool, at date: Date) {
        if !enabled || isPlaying { deadline = nil }
        else if wasPlaying { deadline = date.addingTimeInterval(0.6) }
    }
    func isActive(at date: Date) -> Bool { deadline.map { date < $0 } ?? false }
    mutating func clear() { deadline = nil }
}

/// User-visible pause retention is independent of transient loading protection.
struct PausedPlaybackRetention {
    private var pausedAt: Date?

    mutating func update(isPlaying: Bool, enabled: Bool, at date: Date) {
        if !enabled || isPlaying { pausedAt = nil }
        else if pausedAt == nil { pausedAt = date }
    }

    func deadline(seconds: Int) -> Date? {
        guard seconds > 0 else { return nil }
        return pausedAt?.addingTimeInterval(Double(seconds))
    }

    func isActive(seconds: Int, at date: Date) -> Bool {
        seconds == -1 || (deadline(seconds: seconds).map { date < $0 } ?? false)
    }
}
