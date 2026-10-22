import AppKit
import XCTest
@testable import NotchX

final class TransferTestGate: @unchecked Sendable {
    let started: XCTestExpectation
    private let semaphore = DispatchSemaphore(value: 0)
    init(started: XCTestExpectation) { self.started = started }
    func pause() { started.fulfill(); _ = semaphore.wait(timeout: .now() + 5) }
    func open() { semaphore.signal() }
}

private final class ExportClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Date()
    var date: Date {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

@MainActor
final class ShelfExportLifecycleTests: XCTestCase {
    private func withFiles(_ body: (URL, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: source)
        try await body(root, source)
        XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
    }

    func testSlowDeletionDoesNotBlockLeaseAcquisitionReleaseOrAnotherCleanup() async throws {
        try await withFiles { root, source in
            let clock = ExportClock()
            let gate = TransferTestGate(started: expectation(description: "deletion in progress"))
            defer { gate.open() }
            var operations = ShelfFileOperations.live
            operations.remove = { url in gate.pause(); try FileManager.default.removeItem(at: url) }
            let cache = ShelfExportCache(root: root.appendingPathComponent("exports"), retention: 60,
                                         now: { clock.date }, operations: operations)
            let expired = try cache.copy(source)
            let kept = try cache.copy(source)
            let held = try XCTUnwrap(cache.retain(kept))
            clock.date.addTimeInterval(61)
            let cleanup = Task.detached { cache.cleanup() }
            await fulfillment(of: [gate.started], timeout: 3)
            let responsive = expectation(description: "unrelated lease work proceeds while deletion is blocked")
            let contender = Task.detached {
                let additional = cache.retain(kept)
                XCTAssertNotNil(additional)
                additional?.release()
                XCTAssertNil(cache.retain(expired), "Cannot revive a batch reserved for deletion")
                cache.cleanup()
                responsive.fulfill()
            }
            await fulfillment(of: [responsive], timeout: 1)
            gate.open()
            await cleanup.value
            await contender.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: expired.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
            held.release()
        }
    }

    func testCancelledExportDiscardsCopyThatFinishesLate() async throws {
        try await withFiles { root, source in
            let gate = TransferTestGate(started: expectation(description: "copy in progress"))
            defer { gate.open() }
            let removed = expectation(description: "cancelled batch deleted")
            var operations = ShelfFileOperations.live
            operations.copy = { source, target in
                try FileManager.default.copyItem(at: source, to: target)
                gate.pause()
            }
            operations.remove = { url in try FileManager.default.removeItem(at: url); removed.fulfill() }
            let cache = ShelfExportCache(root: root.appendingPathComponent("exports"), operations: operations)
            let session = ShelfExportSession(cache: cache)
            let copying = Task.detached { try session.copy(source) }
            await fulfillment(of: [gate.started], timeout: 3)
            session.finish()
            session.finish()
            gate.open()
            do { _ = try await copying.value; XCTFail("Cancelled export was delivered") }
            catch { XCTAssertEqual((error as NSError).code, CocoaError.userCancelled.rawValue) }
            await fulfillment(of: [removed], timeout: 3)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.sessionRoot.path), [])
        }
    }

    func testClipboardReplacementReleasesWithoutAnotherExport() async throws {
        try await withFiles { root, source in
            let clock = ExportClock()
            let cache = ShelfExportCache(root: root.appendingPathComponent("exports"), retention: 60, now: { clock.date })
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let coordinator = ShelfExportCoordinator(cache: cache, pollInterval: 0.01, changeCount: { pasteboard.changeCount })
            let session = coordinator.makeSession()
            let exported = try session.copy(source)
            coordinator.keepOnClipboard(session)
            clock.date.addTimeInterval(61)
            cache.cleanup()
            XCTAssertTrue(FileManager.default.fileExists(atPath: exported.path))
            pasteboard.clearContents()
            pasteboard.setString("replacement", forType: .string)
            let batch = exported.deletingLastPathComponent().deletingLastPathComponent()
            let released = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let date = try? batch.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return false }
                return abs(date.timeIntervalSince(clock.date)) < 0.01
            }, object: nil)
            await fulfillment(of: [released], timeout: 3)
            clock.date.addTimeInterval(61)
            cache.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path))
        }
    }

    func testSharingCompletionFailureAndPickerCancellationReleaseOnce() async throws {
        for outcome in ["success", "failure", "cancel", "disable"] {
            try await withFiles { root, source in
                let clock = ExportClock()
                let cache = ShelfExportCache(root: root.appendingPathComponent("exports"), retention: 60, now: { clock.date })
                let export = ShelfExportSession(cache: cache)
                let url = try export.copy(source)
                var finishes = 0
                var choices = 0
                let sharing = ShelfSharingSession(export: export, onServiceChosen: { choices += 1 }) { finishes += 1 }
                let service = NSSharingService(title: "Test", image: NSImage(size: NSSize(width: 1, height: 1)), alternateImage: nil, handler: {})
                let picker = NSSharingServicePicker(items: [url])
                if outcome == "success" || outcome == "failure" {
                    sharing.sharingServicePicker(picker, didChoose: service)
                    sharing.sharingServicePicker(picker, didChoose: service)
                    XCTAssertEqual(choices, 1)
                }
                clock.date.addTimeInterval(61)
                cache.cleanup()
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                if outcome == "success" { sharing.sharingService(service, didShareItems: [url]) }
                else if outcome == "failure" { sharing.sharingService(service, didFailToShareItems: [url], error: CocoaError(.userCancelled)) }
                else if outcome == "cancel" { sharing.sharingServicePicker(picker, didChoose: nil) }
                else { sharing.cancel() }
                sharing.sharingService(service, didShareItems: [url])
                let choicesBeforeLateCallback = choices
                sharing.sharingServicePicker(picker, didChoose: service)
                XCTAssertEqual(choices, choicesBeforeLateCallback, "Late native callbacks must not begin another handoff")
                XCTAssertNil(sharing.sharingServicePicker(picker, delegateFor: service))
                XCTAssertEqual(finishes, 1)
                cache.cleanup()
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Delivered file keeps its grace period")
                clock.date.addTimeInterval(61)
                cache.cleanup()
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }
}
