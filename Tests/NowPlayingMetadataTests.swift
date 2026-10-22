import Foundation
import XCTest
@testable import NotchX

final class NowPlayingMetadataTests: XCTestCase {
    func testOmittedNullAndFullSnapshotsPreserveTheirDistinctMergeSemantics() throws {
        func decode(_ json: String) throws -> NowPlayingUpdate {
            try JSONDecoder().decode(NowPlayingUpdate.self, from: Data(json.utf8))
        }
        let full = try decode("""
        {"diff":false,"payload":{"title":"Track","artist":"Artist","album":"Album",
        "albumArtist":"Album artist","duration":100,"elapsedTime":20,"artworkData":"YWJj",
        "timestamp":"2026-10-17T17:00:00Z","playbackRate":1,"playing":true,
        "trackIdentifier":"track1","isLocalFile":true,
        "parentApplicationBundleIdentifier":"parent","bundleIdentifier":"child"}}
        """)
        let first = full.payload.applying(to: nil, diff: full.diff ?? false)
        let omitted = try decode(#"{"diff":true,"payload":{}}"#)
        let kept = omitted.payload.applying(to: first, diff: true)
        XCTAssertTrue(!omitted.payload.contains(.title))
        XCTAssertTrue(kept.title == "Track" && kept.artist == "Artist" && kept.artworkData == "YWJj")
        XCTAssertTrue(kept.elapsedTime == 20 && kept.playing == true)

        // Explicit null is deletion for every consumed field, not a missing diff key.
        let removed = try decode("""
        {"diff":true,"payload":{"title":null,"artist":null,"album":null,"albumArtist":null,
        "duration":null,"elapsedTime":null,"artworkData":null,"timestamp":null,
        "playbackRate":null,"playing":null,"trackIdentifier":null,"isLocalFile":null,
        "parentApplicationBundleIdentifier":null,"bundleIdentifier":null}}
        """)
        let cleared = removed.payload.applying(to: kept, diff: true)
        XCTAssertTrue(removed.payload.contains(.elapsedTime) && removed.payload.elapsedTime == nil)
        XCTAssertTrue(cleared.title == nil && cleared.artist == nil && cleared.album == nil)
        XCTAssertTrue(cleared.albumArtist == nil && cleared.duration == nil && cleared.elapsedTime == nil)
        XCTAssertTrue(cleared.artworkData == nil && cleared.timestamp == nil && cleared.playbackRate == nil)
        XCTAssertTrue(cleared.playing == nil && cleared.trackIdentifier == nil && cleared.isLocalFile == nil)
        XCTAssertTrue(cleared.parentApplicationBundleIdentifier == nil && cleared.bundleIdentifier == nil)
        let afterDeletion = omitted.payload.applying(to: cleared, diff: true)
        XCTAssertTrue(afterDeletion.title == nil && afterDeletion.artworkData == nil)

        // Parent and child identities merge independently; deleting parent reveals child.
        let parentRemoved = try decode(#"{"diff":true,"payload":{"parentApplicationBundleIdentifier":null}}"#)
        let identity = parentRemoved.payload.applying(to: first, diff: true)
        XCTAssertTrue(identity.parentApplicationBundleIdentifier == nil)
        XCTAssertTrue((identity.parentApplicationBundleIdentifier ?? identity.bundleIdentifier) == "child")
        XCTAssertTrue(identity.artworkData == nil, "Source change retained artwork from the previous source")
        let changed = try decode(#"{"diff":true,"payload":{"title":"Next","playing":false,"elapsedTime":0}}"#)
        let next = changed.payload.applying(to: identity, diff: true)
        XCTAssertTrue(next.title == "Next" && next.playing == false && next.elapsedTime == 0)
        XCTAssertTrue(next.artist == "Artist" && next.artworkData == nil)

        // Full snapshots replace prior state, including an empty no-player snapshot.
        let replacement = try decode(#"{"diff":false,"payload":{"title":"Fresh"}}"#)
        let replaced = replacement.payload.applying(to: first, diff: false)
        XCTAssertTrue(replaced.title == "Fresh" && replaced.artist == nil && replaced.artworkData == nil)
        let empty = omitted.payload.applying(to: first, diff: false)
        XCTAssertTrue(empty.title == nil && empty.bundleIdentifier == nil)
        let initialDiff = changed.payload.applying(to: nil, diff: true)
        XCTAssertTrue(initialDiff.title == "Next" && initialDiff.artist == nil)
        let legacy = try decode(#"{"payload":{"title":"Legacy"}}"#)
        XCTAssertTrue(legacy.diff == nil)
        XCTAssertTrue(legacy.payload.applying(to: first, diff: legacy.diff ?? false).artist == nil)

    }
}
