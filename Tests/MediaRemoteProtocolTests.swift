import XCTest
import AppKit
@testable import NotchX

final class MediaRemoteProtocolTests: XCTestCase {
    func testNetEaseTransportUUIDChangesDoNotReplaceTheDisplayedTrack() throws {
        let original = try payload(#"{"bundleIdentifier":"com.netease.163music","title":"Old","artist":"Singer","album":"Album","contentItemIdentifier":"before","artworkData":"cover","playing":true}"#)
        let transport = try payload(#"{"contentItemIdentifier":"after","playing":false}"#)
        let refreshed = transport.applying(to: original, diff: true)
        XCTAssertTrue(refreshed.isSameTrack(as: original))
        XCTAssertEqual(refreshed.stableIdentifier, original.stableIdentifier)
        XCTAssertEqual(refreshed.artworkData, "cover")
        let next = try payload(#"{"title":"New","contentItemIdentifier":"next"}"#).applying(to: refreshed, diff: true)
        XCTAssertFalse(next.isSameTrack(as: refreshed))
        XCTAssertNil(next.artworkData)
        let otherRecording = try payload(#"{"artist":"Other singer"}"#).applying(to: refreshed, diff: true)
        XCTAssertFalse(otherRecording.isSameTrack(as: refreshed))
    }

    @MainActor
    func testTransportAndRepeatedFullSnapshotsReuseArtworkUntilNewBytesArrive() throws {
        func cover(_ color: NSColor) throws -> String {
            let image = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
            return try XCTUnwrap(image.tiffRepresentation).base64EncodedString()
        }
        let firstBytes = try cover(.red)
        let nextBytes = try cover(.blue)
        func event(_ title: String, _ id: String, _ art: String?) throws -> NowPlayingPayload {
            var fields: [String: Any] = ["bundleIdentifier": "com.netease.163music", "title": title,
                                         "contentItemIdentifier": id, "playing": true]
            fields["artworkData"] = art
            return try JSONDecoder().decode(NowPlayingPayload.self, from: JSONSerialization.data(withJSONObject: fields))
        }
        var decoder = PlaybackArtworkDecoder()
        let old = try event("Old", "one", firstBytes)
        let displayed = try XCTUnwrap(decoder.decode(old.artworkData))
        for id in ["two", "three"] {
            let refresh = try event("Old", id, firstBytes)
            XCTAssertTrue(refresh.isSameTrack(as: old))
            XCTAssertTrue(decoder.decode(refresh.artworkData) === displayed)
        }
        let next = try event("New", "four", nil)
        XCTAssertFalse(next.isSameTrack(as: old))
        XCTAssertNil(decoder.decode(next.artworkData))
        let late = try event("New", "four", nextBytes)
        let replacement = try XCTUnwrap(decoder.decode(late.artworkData))
        XCTAssertFalse(replacement === displayed)
        XCTAssertTrue(decoder.decode(late.artworkData) === replacement)
    }

    func testNetEasePublishesCompleteTrackAfterMetadataSettles() throws {
        var buffer = NetEasePlaybackPublication()
        let t = Date(timeIntervalSince1970: 100)
        let old = try payload(#"{"bundleIdentifier":"com.netease.163music","title":"Old","artist":"A","duration":294,"playing":true,"artworkData":"old"}"#)
        XCTAssertEqual(buffer.receive(old, at: t)?.title, "Old")
        let partial = try payload(#"{"bundleIdentifier":"com.netease.163music","title":"New","artist":"B","duration":294,"playing":true,"artworkData":"new"}"#)
        XCTAssertNil(buffer.receive(partial, at: t.addingTimeInterval(0.1)))
        let complete = try payload(#"{"bundleIdentifier":"com.netease.163music","title":"New","artist":"B/C","duration":261,"playing":true,"artworkData":"new","elapsedTime":1}"#)
        XCTAssertNil(buffer.receive(complete, at: t.addingTimeInterval(0.5)))
        XCTAssertNil(buffer.flush(at: t.addingTimeInterval(0.8)))
        // Position-only samples must not keep restarting the quiet window.
        let tick = try payload(#"{"elapsedTime":2}"#).applying(to: complete, diff: true)
        XCTAssertNil(buffer.receive(tick, at: t.addingTimeInterval(0.9)))
        let result = try XCTUnwrap(buffer.flush(at: t.addingTimeInterval(1.01)))
        XCTAssertEqual(result.title, "New")
        XCTAssertEqual(result.artist, "B/C")
        XCTAssertEqual(result.duration, 261)
        XCTAssertEqual(result.artworkData, "new")
        XCTAssertEqual(result.elapsedTime, 2)
    }

    func testNetEaseLoadingPauseDoesNotFlashButConfirmedUserPauseIsImmediate() throws {
        var buffer = NetEasePlaybackPublication()
        let t = Date(timeIntervalSince1970: 100)
        let playing = try payload(#"{"bundleIdentifier":"com.netease.163music","title":"Track","playing":true}"#)
        let paused = try payload(#"{"playing":false}"#).applying(to: playing, diff: true)
        _ = buffer.receive(playing, at: t)
        XCTAssertNil(buffer.receive(paused, at: t.addingTimeInterval(0.1)))
        XCTAssertNil(buffer.flush(at: t.addingTimeInterval(0.5)))
        XCTAssertEqual(buffer.receive(playing, at: t.addingTimeInterval(0.55))?.playing, true)
        XCTAssertNil(buffer.flush(at: t.addingTimeInterval(1)))
        buffer.expectPlayback(false, at: t.addingTimeInterval(2))
        XCTAssertEqual(buffer.receive(paused, at: t.addingTimeInterval(2.01))?.playing, false)
        buffer.expectPlayback(true, at: t.addingTimeInterval(3))
        XCTAssertEqual(buffer.receive(playing, at: t.addingTimeInterval(3.01))?.playing, true)
        // Failed or superseded play/pause commands must not authorize loading pauses.
        buffer.expectPlayback(false, at: t.addingTimeInterval(3.5))
        buffer.cancelPlaybackIntent()
        // A genuine pause from the player is eventually published without an intent.
        XCTAssertNil(buffer.receive(paused, at: t.addingTimeInterval(4)))
        XCTAssertEqual(buffer.flush(at: t.addingTimeInterval(4.66))?.playing, false)
    }

    func testNetEaseRapidSkippingWaitsForLatestStableSong() throws {
        var buffer = NetEasePlaybackPublication()
        let t = Date(timeIntervalSince1970: 100)
        _ = buffer.receive(try payload(#"{"bundleIdentifier":"com.netease.163music","title":"Old","playing":true}"#), at: t)
        for i in 0..<5 {
            let event = try payload("{\"bundleIdentifier\":\"com.netease.163music\",\"title\":\"Track \(i)\",\"playing\":true}")
            XCTAssertNil(buffer.receive(event, at: t.addingTimeInterval(0.1 + Double(i) * 0.3)))
        }
        XCTAssertNil(buffer.flush(at: t.addingTimeInterval(1.61)))
        XCTAssertEqual(buffer.flush(at: t.addingTimeInterval(1.81))?.title, "Track 4")
    }

    func testNetEaseSkipHoldDoesNotPublishAnIntermediateLoadingPause() throws {
        var buffer = NetEasePlaybackPublication()
        let t = Date(timeIntervalSince1970: 100)
        let old = try payload(#"{"bundleIdentifier":"com.netease.163music","title":"Old","playing":true,"duration":294}"#)
        _ = buffer.receive(old, at: t)
        buffer.expectTrackChange(at: t)
        let loading = try payload(#"{"title":"New","playing":false}"#).applying(to: old, diff: true)
        XCTAssertNil(buffer.receive(loading, at: t.addingTimeInterval(0.1)))
        XCTAssertNil(buffer.flush(at: t.addingTimeInterval(0.9)))
        let ready = try payload(#"{"playing":true,"duration":261}"#).applying(to: loading, diff: true)
        XCTAssertNil(buffer.receive(ready, at: t.addingTimeInterval(1)))
        let result = try XCTUnwrap(buffer.flush(at: t.addingTimeInterval(1.51)))
        XCTAssertEqual(result.duration, 261)
        XCTAssertEqual(result.playing, true)
    }

    func testNetEaseRepeatedSkipExtendsLoadingHoldAndConfirmedPauseReleasesIt() throws {
        var buffer = NetEasePlaybackPublication()
        let t = Date(timeIntervalSince1970: 100)
        let old = try payload(#"{"bundleIdentifier":"com.netease.163music","title":"Old","playing":true}"#)
        let loading = try payload(#"{"title":"New","playing":false}"#).applying(to: old, diff: true)
        _ = buffer.receive(old, at: t)
        buffer.expectTrackChange(at: t)
        XCTAssertNil(buffer.receive(loading, at: t.addingTimeInterval(0.1)))
        buffer.expectTrackChange(at: t.addingTimeInterval(1.5))
        XCTAssertNil(buffer.flush(at: t.addingTimeInterval(2.01)))
        XCTAssertNil(buffer.receive(loading, at: t.addingTimeInterval(2.1)))
        var withoutPause = buffer
        XCTAssertEqual(withoutPause.flush(at: t.addingTimeInterval(3.51))?.title, "New")

        buffer.expectPlayback(false, at: t.addingTimeInterval(2.2))
        // Intent alone must not treat a pre-command loading sample as confirmation.
        XCTAssertNil(buffer.flush(at: t.addingTimeInterval(2.21)))
        XCTAssertNil(buffer.receive(loading, at: t.addingTimeInterval(2.3)))
        let result = try XCTUnwrap(buffer.flush(at: t.addingTimeInterval(2.81)))
        XCTAssertEqual(result.title, "New")
        XCTAssertEqual(result.playing, false)
    }

    func testNetEasePendingSongCannotSurviveSourceChangeOrLifecycleReset() throws {
        var buffer = NetEasePlaybackPublication()
        let t = Date(timeIntervalSince1970: 100)
        let old = try payload(#"{"bundleIdentifier":"com.netease.163music","title":"Old","playing":true}"#)
        let next = try payload(#"{"title":"New"}"#).applying(to: old, diff: true)
        _ = buffer.receive(old, at: t)
        XCTAssertNil(buffer.receive(next, at: t.addingTimeInterval(0.1)))
        let other = try payload(#"{"bundleIdentifier":"com.apple.Music","title":"Other","playing":true}"#)
        XCTAssertEqual(buffer.receive(other, at: t.addingTimeInterval(0.2))?.title, "Other")
        XCTAssertNil(buffer.flush(at: t.addingTimeInterval(2)))
        _ = buffer.receive(old, at: t.addingTimeInterval(3))
        XCTAssertNil(buffer.receive(next, at: t.addingTimeInterval(3.1)))
        buffer.reset()
        XCTAssertNil(buffer.flush(at: t.addingTimeInterval(5)))
    }

    func testNewTrackDoesNotInheritPreviousArtworkWhilePauseRetainsIt() throws {
        let old = try payload(#"{"title":"Old","uniqueIdentifier":"one","artworkData":"old-art"}"#)
        let paused = try payload(#"{"playing":false}"#).applying(to: old, diff: true)
        XCTAssertEqual(paused.artworkData, "old-art")
        let changed = try payload(#"{"title":"New"}"#).applying(to: paused, diff: true)
        XCTAssertFalse(changed.isSameTrack(as: paused))
        XCTAssertNil(changed.artworkData)
        let lateArt = try payload(#"{"artworkData":"new-art"}"#).applying(to: changed, diff: true)
        XCTAssertEqual(lateArt.title, "New")
        XCTAssertEqual(lateArt.artworkData, "new-art")
        XCTAssertTrue(lateArt.isSameTrack(as: changed))
    }

    private func payload(_ json: String) throws -> NowPlayingPayload {
        try JSONDecoder().decode(NowPlayingPayload.self, from: Data(json.utf8))
    }

    func testStreamFramingPreservesEverySplitOfChineseAndEmoji() throws {
        let bytes = Data((#"{"title":"梦醒时分 🎵"}"# + "\n" + #"{"artist":"梁静茹"}"# + "\n").utf8)
        for split in 0...bytes.count {
            var buffer = MediaRemoteLineBuffer()
            let lines = try buffer.append(Data(bytes.prefix(split))) + buffer.append(Data(bytes.dropFirst(split)))
            XCTAssertEqual(lines.count, 2)
            XCTAssertEqual(try JSONDecoder().decode(NowPlayingPayload.self, from: lines[0]).title, "梦醒时分 🎵")
            XCTAssertEqual(try JSONDecoder().decode(NowPlayingPayload.self, from: lines[1]).artist, "梁静茹")
        }
        var bytewise = MediaRemoteLineBuffer()
        var lines: [Data] = []
        for byte in bytes { lines += try bytewise.append(Data([byte])) }
        XCTAssertEqual(lines.count, 2)
    }

    func testStreamFramingBoundsIncompleteLinesAndKeepsLaterValidFrames() throws {
        var buffer = MediaRemoteLineBuffer(maximumLineBytes: 4)
        XCTAssertEqual(try buffer.append(Data("a\r\n\n1234\n".utf8)), [Data("a\r".utf8), Data("1234".utf8)])
        XCTAssertTrue(try buffer.append(Data("1234".utf8)).isEmpty)
        XCTAssertThrowsError(try buffer.append(Data("5".utf8)))
        XCTAssertEqual(try buffer.append(Data("ok\n".utf8)), [Data("ok".utf8)])
    }

    func testSourceTimestampCalibratesDelayedUpdatesWithoutResettingTrackPosition() throws {
        let incoming = try payload(#"{"title":"Track","uniqueIdentifier":"one","duration":300,"elapsedTime":120,"timestamp":"2026-10-18T00:00:00.500Z","playing":true,"playbackRate":0.5}"#)
        let now = try XCTUnwrap(incoming.timestampDate).addingTimeInterval(10)
        XCTAssertEqual(incoming.calibratedElapsedTime(incoming: incoming, diff: false, previousElapsed: 0, trackChanged: true, now: now), 125)
        XCTAssertEqual(incoming.calibratedElapsedTime(incoming: incoming, diff: false, previousElapsed: 0, trackChanged: true, now: now.addingTimeInterval(-20)), 120)
    }

    func testStableIdentitySurvivesLateMetadataButDistinguishesSameNamedTracks() throws {
        let previous = try payload(#"{"title":"Same name","uniqueIdentifier":42,"bundleIdentifier":"player","duration":300,"elapsedTime":50}"#)
        let artist = try payload(#"{"artist":"Arrived later"}"#)
        let enriched = artist.applying(to: previous, diff: true)
        XCTAssertEqual(enriched.stableIdentifier, "42")
        XCTAssertTrue(enriched.isSameTrack(as: previous))
        XCTAssertEqual(enriched.calibratedElapsedTime(incoming: artist, diff: true, previousElapsed: 55, trackChanged: false, now: Date()), 55)
        let replacement = try payload(#"{"uniqueIdentifier":43}"#).applying(to: enriched, diff: true)
        XCTAssertFalse(replacement.isSameTrack(as: enriched))
        let fallback = try payload(#"{"uniqueIdentifier":"","contentItemIdentifier":"content"}"#)
        XCTAssertEqual(fallback.stableIdentifier, "content")
    }

    func testPauseSeekNullAndFullSnapshotsRetainTheirProtocolMeaning() throws {
        let previous = try payload(#"{"title":"Track","duration":300,"elapsedTime":20,"playing":true,"uniqueIdentifier":"one","artworkData":"art"}"#)
        let pause = try payload(#"{"playing":false}"#)
        let paused = pause.applying(to: previous, diff: true)
        XCTAssertEqual(paused.calibratedElapsedTime(incoming: pause, diff: true, previousElapsed: 27, trackChanged: false, now: Date()), 27)
        let cleared = try payload(#"{"elapsedTime":null,"timestamp":"2026-10-18T00:00:00Z","uniqueIdentifier":null}"#)
        let removed = cleared.applying(to: previous, diff: true)
        XCTAssertEqual(removed.stableIdentifier, "")
        XCTAssertNil(removed.calibratedElapsedTime(incoming: cleared, diff: true, previousElapsed: 27, trackChanged: false, now: Date()))
        let seek = try payload(#"{"elapsedTime":180,"playing":false}"#)
        XCTAssertEqual(seek.applying(to: paused, diff: true).calibratedElapsedTime(incoming: seek, diff: true, previousElapsed: 27, trackChanged: false, now: Date()), 180)
        let empty = try payload("{}")
        XCTAssertNil(empty.applying(to: previous, diff: false).title)
        XCTAssertNil(empty.applying(to: previous, diff: false).artworkData)
    }

    func testPauseResumeAndMissingPositionDoNotRestartHalfPlayedTrack() throws {
        let original = try payload(#"{"title":"Track","uniqueIdentifier":"one","duration":300,"elapsedTime":0,"timestamp":"2026-10-18T00:00:00Z","playing":true,"playbackRate":1}"#)
        let now = try XCTUnwrap(original.timestampDate).addingTimeInterval(150)
        for playing in [false, true] {
            let change = try payload("{\"playing\":\(playing),\"timestamp\":\"2026-10-18T00:02:30Z\"}")
            let merged = change.applying(to: original, diff: true)
            XCTAssertEqual(merged.calibratedElapsedTime(incoming: change, previous: original, diff: true,
                                                       previousElapsed: 150, trackChanged: false, now: now), 150)
        }
        let full = try payload(#"{"title":"Track","uniqueIdentifier":"one","duration":300,"playing":true}"#)
        XCTAssertEqual(full.calibratedElapsedTime(incoming: full, previous: original, diff: false,
                                                 previousElapsed: 150, trackChanged: false, now: now), 150)
        XCTAssertNil(full.calibratedElapsedTime(incoming: full, diff: false,
                                               previousElapsed: nil, trackChanged: true, now: now))
    }

    func testRepeatedFullAnchorSurvivesPauseResumeButNewAnchorCanSeekToZero() throws {
        let original = try payload(#"{"duration":300,"elapsedTime":0,"timestamp":"2026-10-18T00:00:00Z","playing":true,"playbackRate":1}"#)
        let now = try XCTUnwrap(original.timestampDate).addingTimeInterval(150)
        let paused = try payload(#"{"duration":300,"elapsedTime":0,"timestamp":"2026-10-18T00:00:00Z","playing":false,"playbackRate":0}"#)
        XCTAssertEqual(paused.calibratedElapsedTime(incoming: paused, previous: original, diff: false,
                                                   previousElapsed: 150, trackChanged: false, now: now), 150)
        XCTAssertEqual(original.calibratedElapsedTime(incoming: original, previous: paused, diff: false,
                                                     previousElapsed: 150, trackChanged: false, now: now.addingTimeInterval(60)), 150)
        let seek = try payload(#"{"duration":300,"elapsedTime":0,"timestamp":"2026-10-18T00:02:30Z","playing":true,"playbackRate":1}"#)
        XCTAssertEqual(seek.calibratedElapsedTime(incoming: seek, previous: original, diff: false,
                                                 previousElapsed: 150, trackChanged: false, now: now), 0)
        XCTAssertEqual(seek.calibratedElapsedTime(incoming: seek, previous: original, diff: false,
                                                 previousElapsed: 150, trackChanged: false, now: now.addingTimeInterval(5)), 5)
    }

    func testSeekWithoutTimestampDoesNotReuseOldTimestampAndTrackChangeDropsPosition() throws {
        let original = try payload(#"{"duration":300,"elapsedTime":120,"timestamp":"2026-10-18T00:00:00Z","playing":true,"playbackRate":1}"#)
        let now = try XCTUnwrap(original.timestampDate).addingTimeInterval(60)
        let seek = try payload(#"{"elapsedTime":20}"#)
        let merged = seek.applying(to: original, diff: true)
        XCTAssertEqual(merged.calibratedElapsedTime(incoming: seek, previous: original, diff: true,
                                                   previousElapsed: 180, trackChanged: false, now: now), 20)
        let next = try payload(#"{"title":"Next"}"#)
        XCTAssertNil(next.applying(to: original, diff: true).calibratedElapsedTime(incoming: next, diff: true,
                                                                               previousElapsed: 180, trackChanged: true, now: now))
    }

    func testNetEaseSourceSupportsMetadataAndMissingOptionalModes() throws {
        let netease = try payload(#"{"bundleIdentifier":"com.netease.163music","parentApplicationBundleIdentifier":"","title":"测试歌曲","artist":"测试歌手","duration":300,"elapsedTime":150,"playing":true,"artworkData":"YWJj","shuffleMode":1,"repeatMode":3}"#)
        XCTAssertEqual(netease.sourceBundleIdentifier, "com.netease.163music")
        XCTAssertEqual(netease.title, "测试歌曲")
        XCTAssertEqual(netease.artworkData, "YWJj")
        XCTAssertEqual(netease.calibratedElapsedTime(incoming: netease, diff: false, previousElapsed: nil,
                                                    trackChanged: true, now: Date()), 150)
        XCTAssertEqual(netease.shuffleMode, .off)
        XCTAssertEqual(netease.repeatMode, .playlist)
        let unchanged = try payload(#"{"playing":false}"#).applying(to: netease, diff: true)
        XCTAssertEqual(unchanged.repeatMode, .playlist)
        let removed = try payload(#"{"shuffleMode":null,"repeatMode":99}"#).applying(to: netease, diff: true)
        XCTAssertNil(removed.shuffleMode)
        XCTAssertNil(removed.repeatMode)
        let replaced = try payload(#"{"bundleIdentifier":"another.player","title":"Other"}"#).applying(to: netease, diff: false)
        XCTAssertFalse(replaced.isSameTrack(as: netease))
        XCTAssertNil(replaced.shuffleMode)
        XCTAssertNil(replaced.repeatMode)
        let unsupported = try payload(#"{"title":"Track","shuffleMode":"unknown","repeatMode":0}"#)
        XCTAssertEqual(unsupported.title, "Track")
        XCTAssertNil(unsupported.shuffleMode)
        XCTAssertNil(unsupported.repeatMode)
    }

    func testPlaybackModeCommandsRequireMatchingPlayerFeedback() {
        let shuffle = PlaybackModeCommand.shuffle(PlaybackShuffleMode.off.toggled)
        XCTAssertEqual(shuffle.arguments, ["shuffle", "3"])
        XCTAssertFalse(shuffle.isConfirmed(shuffle: nil, repeatMode: .playlist))
        XCTAssertFalse(shuffle.isConfirmed(shuffle: .off, repeatMode: .playlist))
        XCTAssertTrue(shuffle.isConfirmed(shuffle: .tracks, repeatMode: nil))
        XCTAssertEqual(PlaybackModeCommand.shuffle(PlaybackShuffleMode.albums.toggled).arguments, ["shuffle", "1"])
        let repeatAll = PlaybackModeCommand.repeatMode(PlaybackRepeatMode.off.next)
        XCTAssertEqual(repeatAll.arguments, ["repeat", "3"])
        XCTAssertFalse(repeatAll.isConfirmed(shuffle: .tracks, repeatMode: .off))
        XCTAssertTrue(repeatAll.isConfirmed(shuffle: nil, repeatMode: .playlist))
        XCTAssertEqual(PlaybackRepeatMode.playlist.next, .track)
        XCTAssertEqual(PlaybackRepeatMode.track.next, .off)
    }
}

final class PendingPlaybackSeekTests: XCTestCase {
    func testForwardAndBackwardSeekIgnoreOldPositionUntilPlayerConfirms() {
        let now = Date(timeIntervalSince1970: 1000)
        for target: Double in [30, 240] {
            let request = PendingPlaybackSeek(trackID: "player/track", target: target,
                requestedAt: now, duration: 300, rate: 1, isPlaying: true)
            XCTAssertEqual(request.position(at: now), target)
            XCTAssertFalse(request.accepts(position: 150, trackID: "player/track", sampledAt: now, now: now))
            XCTAssertFalse(request.accepts(position: target, trackID: "player/track",
                                            sampledAt: now.addingTimeInterval(-20), now: now))
            XCTAssertTrue(request.accepts(position: target + 1, trackID: "player/track",
                                           sampledAt: now.addingTimeInterval(1), now: now.addingTimeInterval(1)))
        }
    }

    func testPausedZeroAndEndPositionsAreValidButUnknownAndOtherTracksAreNot() {
        let now = Date(timeIntervalSince1970: 1000)
        for target: Double in [0, 300] {
            let request = PendingPlaybackSeek(trackID: "a", target: target,
                requestedAt: now, duration: 300, rate: 0, isPlaying: false)
            XCTAssertEqual(request.position(at: now.addingTimeInterval(2)), target)
            XCTAssertTrue(request.accepts(position: target, trackID: "a", sampledAt: nil, now: now))
            XCTAssertFalse(request.accepts(position: target, trackID: "b", sampledAt: now, now: now))
            XCTAssertFalse(request.accepts(position: nil, trackID: "a", sampledAt: now, now: now))
            XCTAssertFalse(request.accepts(position: .nan, trackID: "a", sampledAt: now, now: now))
        }
    }

    func testNewSeekDoesNotAcceptCompletionOfAnEarlierSeek() {
        let now = Date(timeIntervalSince1970: 1000)
        let first = PendingPlaybackSeek(trackID: "a", target: 60, requestedAt: now, duration: 300, rate: 1, isPlaying: true)
        let latest = PendingPlaybackSeek(trackID: "a", target: 220, requestedAt: now.addingTimeInterval(1),
                                        duration: 300, rate: 1, isPlaying: true)
        XCTAssertNotEqual(first.id, latest.id)
        XCTAssertFalse(latest.accepts(position: 61, trackID: "a", sampledAt: now.addingTimeInterval(1), now: now.addingTimeInterval(1)))
        XCTAssertTrue(latest.accepts(position: 221, trackID: "a", sampledAt: now.addingTimeInterval(2), now: now.addingTimeInterval(2)))
    }
}

final class AdapterProcessRunnerTests: XCTestCase {
    func testStoppingOwnedStreamEscalatesWithoutStoppingOtherProcesses() async throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "trap '' TERM; printf ready; while :; do :; done"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        // Wait for the fixture to install its SIGTERM handler off the main actor.
        let ready = await Task.detached { output.fileHandleForReading.readData(ofLength: 5) }.value
        XCTAssertEqual(String(data: ready, encoding: .utf8), "ready")
        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["10"]
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }
        AdapterProcessRunner.stopOwnedProcess(process)
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning, Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(process.isRunning, "A disabled module must not leave its stream child alive")
        XCTAssertTrue(unrelated.isRunning)
    }

    func testTimeoutStillStopsHelperAfterItClosesStandardOutput() async {
        do {
            _ = try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exec 1>&-; exec /bin/sleep 5"], timeout: 0.1)
            XCTFail("Closed output bypassed the process deadline")
        } catch { XCTAssertEqual(error as? AdapterProcessError, .timedOut) }
    }

    func testSuccessfulCommandAndLaunchFailureFinish() async throws {
        let data = try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["adapter-output"])
        XCTAssertEqual(String(data: data, encoding: .utf8), "adapter-output\n")
        do {
            _ = try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/nonexistent/notchx-helper"), arguments: [])
            XCTFail("Missing helper succeeded")
        } catch {}
    }

    func testContinuousOutputIsStoppedAtTheLimit() async throws {
        do {
            _ = try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/yes"), arguments: [], maximumOutputBytes: 1024)
            XCTFail("Unbounded output succeeded")
        } catch { XCTAssertEqual(error as? AdapterProcessError, .outputTooLarge) }
    }

    func testTimeoutAndCancellationKillAHelperThatIgnoresTermination() async throws {
        for cancel in [false, true] {
            let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: pidFile) }
            let command = Task {
                try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; while :; do :; done", "notchx-test", pidFile.path],
                    timeout: cancel ? 5 : 0.5)
            }
            if cancel {
                for _ in 0..<200 {
                    if FileManager.default.fileExists(atPath: pidFile.path) { break }
                    try await Task.sleep(for: .milliseconds(10))
                }
                command.cancel()
            }
            do { _ = try await command.value; XCTFail("Helper unexpectedly succeeded") }
            catch { XCTAssertEqual(error as? AdapterProcessError, cancel ? .cancelled : .timedOut) }
            let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            XCTAssertEqual(kill(pid, 0), -1, "Helper survived completion")
            XCTAssertEqual(errno, ESRCH)
        }
    }

    func testTimeoutAndCancellationDoNotLeaveAContinuationWaiting() async throws {
        do {
            _ = try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"], timeout: 0.05)
            XCTFail("Timeout succeeded")
        } catch { XCTAssertEqual(error as? AdapterProcessError, .timedOut) }
        let command = Task {
            try await AdapterProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["5"])
        }
        command.cancel()
        do { _ = try await command.value; XCTFail("Cancelled command succeeded") }
        catch { XCTAssertEqual(error as? AdapterProcessError, .cancelled) }
    }
}
