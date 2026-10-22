import Combine
import XCTest
@testable import NotchX

private final class RemovalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var blockedPath: String?
    private var failures: Set<String> = []
    private var calls: [String: Int] = [:]
    let gate: TransferTestGate?

    init(blocking path: String? = nil, gate: TransferTestGate? = nil) {
        blockedPath = path
        self.gate = gate
    }
    func fail(_ path: String, enabled: Bool) {
        lock.lock()
        if enabled { failures.insert(path) } else { failures.remove(path) }
        lock.unlock()
    }
    func count(_ path: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return calls[path, default: 0]
    }
    func remove(_ url: URL) throws {
        XCTAssertFalse(Thread.isMainThread, "Owned-file deletion must never run on the UI thread")
        lock.lock()
        calls[url.path, default: 0] += 1
        let shouldBlock = url.path == blockedPath
        if shouldBlock { blockedPath = nil }
        lock.unlock()
        if shouldBlock { gate?.pause() }
        lock.lock()
        let shouldFail = failures.contains(url.path)
        lock.unlock()
        if shouldFail { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.removeItem(at: url)
    }
}

@MainActor
final class ShelfRemovalTests: XCTestCase {
    private func withStore(_ body: (ShelfStore, URL, UserDefaults, RemovalProbe) async throws -> Void,
                           blockingName: String? = nil, gate: TransferTestGate? = nil) async throws {
        let domain = "app.notchx.tests.removal.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managed = root.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let probe = RemovalProbe(blocking: blockingName.map { managed.appendingPathComponent($0).path }, gate: gate)
        var operations = ShelfFileOperations.live
        operations.remove = { try probe.remove($0) }
        let exports = ShelfExportCoordinator(cache: ShelfExportCache(root: root.appendingPathComponent("exports")))
        let store = ShelfStore(preferences: preferences, managedRoot: managed, fileOperations: operations, exports: exports)
        store.setEnabled(true)
        defer {
            gate?.open()
            store.setEnabled(false)
            preferences.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(store, root, preferences, probe)
    }

    private func owned(_ root: URL, _ name: String, pinned: Bool = false, ageDays: Int = 0) throws -> ShelfItem {
        let url = root.appendingPathComponent("managed/" + name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("content".utf8).write(to: url.appendingPathComponent("document.txt"))
        return ShelfItem(kind: .folder, displayName: name, path: url.path,
                         addedAt: Date().addingTimeInterval(-Double(ageDays) * 86400),
                         isPinned: pinned, ownership: .managedCopy)
    }

    private func waitForIdle(_ store: ShelfStore) async {
        guard !store.removingItemIDs.isEmpty else { return }
        let done = expectation(description: "removal progress completes")
        let observation = store.$removingItemIDs.sink { if $0.isEmpty { done.fulfill() } }
        await fulfillment(of: [done], timeout: 3)
        observation.cancel()
    }

    func testSlowRemoveKeepsUIResponsiveCoalescesRequestsAndPreservesNewItems() async throws {
        let gate = TransferTestGate(started: expectation(description: "folder removal started"))
        try await withStore({ store, root, preferences, probe in
            let item = try owned(root, "slow")
            store.add([item])
            let removal = store.remove(item)
            await fulfillment(of: [gate.started], timeout: 3)
            XCTAssertTrue(store.isRemoving(item))
            XCTAssertTrue(store.items.contains { $0.id == item.id })
            let newItem = ShelfItem.text("added while deletion is blocked")
            XCTAssertEqual(store.add([newItem]), 1)
            XCTAssertEqual(store.add([ShelfItem(kind: .file, displayName: "same path", path: item.path)]), 0)
            XCTAssertEqual(store.add([ShelfItem(kind: .file, displayName: "child", path: item.path! + "/document.txt")]), 0)
            store.remove(item)
            store.togglePinned(item)
            XCTAssertFalse(try XCTUnwrap(store.items.first { $0.id == item.id }).isPinned)
            gate.open()
            await removal?.value
            XCTAssertEqual(probe.count(item.path!), 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: item.path!))
            XCTAssertEqual(store.items.map(\.id), [newItem.id])
            let reopened = ShelfStore(preferences: preferences, managedRoot: root.appendingPathComponent("managed"))
            XCTAssertEqual(reopened.items.map(\.id), [newItem.id])
            XCTAssertTrue(store.removingItemIDs.isEmpty)
        }, blockingName: "slow", gate: gate)
    }

    func testClearRetainsFailuresForRetryAndNeverDeletesReferencesOrEscapedPaths() async throws {
        try await withStore { store, root, preferences, probe in
            let good = try owned(root, "good")
            let failed = try owned(root, "failed")
            probe.fail(failed.path!, enabled: true)
            let original = root.appendingPathComponent("original.txt")
            try Data("original".utf8).write(to: original)
            let reference = ShelfItem.file(from: original)
            let forged = ShelfItem(kind: .image, displayName: "outside", path: original.path, ownership: .managedCopy)
            let link = root.appendingPathComponent("managed/escape")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
            let escaped = ShelfItem(kind: .file, displayName: "escaped", path: link.appendingPathComponent("original.txt").path, ownership: .managedCopy)
            let missing = ShelfItem(kind: .file, displayName: "missing", path: root.appendingPathComponent("managed/missing.txt").path, ownership: .managedCopy)
            store.add([good, failed, reference, forged, escaped, missing])
            await store.clear()?.value
            XCTAssertEqual(store.items.map(\.id), [failed.id])
            XCTAssertEqual(store.removalFailures, [failed.id])
            XCTAssertTrue(FileManager.default.fileExists(atPath: failed.path!))
            XCTAssertFalse(FileManager.default.fileExists(atPath: good.path!))
            XCTAssertEqual(probe.count(original.path), 0)
            XCTAssertEqual(probe.count(escaped.path!), 0)
            XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
            let reopened = ShelfStore(preferences: preferences, managedRoot: root.appendingPathComponent("managed"))
            XCTAssertEqual(reopened.items.map(\.id), [failed.id])
            probe.fail(failed.path!, enabled: false)
            await store.retryFailedRemovals()?.value
            XCTAssertTrue(store.items.isEmpty)
            XCTAssertTrue(store.removalFailures.isEmpty)
            XCTAssertEqual(probe.count(failed.path!), 2)
            XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        }
    }

    func testClearUnpinnedRechecksQueuedPinChanges() async throws {
        let gate = TransferTestGate(started: expectation(description: "first unpinned deletion started"))
        try await withStore({ store, root, _, probe in
            let first = try owned(root, "first")
            let queued = try owned(root, "queued")
            let pinned = try owned(root, "pinned", pinned: true)
            store.add([first, queued, pinned])
            let clear = store.clearUnpinned()
            await fulfillment(of: [gate.started], timeout: 3)
            store.togglePinned(queued)
            store.clearUnpinned()
            let added = ShelfItem.text("new")
            store.add([added])
            gate.open()
            await clear?.value
            XCTAssertEqual(Set(store.items.map(\.id)), [queued.id, pinned.id, added.id])
            XCTAssertTrue(try XCTUnwrap(store.items.first { $0.id == queued.id }).isPinned)
            XCTAssertEqual(probe.count(queued.path!), 0)
            XCTAssertEqual(probe.count(pinned.path!), 0)
        }, blockingName: "first", gate: gate)
    }

    func testDisableCancelsQueuedWorkButReconcilesInFlightSuccessOrFailure() async throws {
        for fail in [false, true] {
            let gate = TransferTestGate(started: expectation(description: "delete before disabling"))
            try await withStore({ store, root, _, probe in
                let first = try owned(root, "first")
                let queued = try owned(root, "queued")
                probe.fail(first.path!, enabled: fail)
                store.add([first, queued])
                let clear = store.clear()
                await fulfillment(of: [gate.started], timeout: 3)
                store.setEnabled(false)
                XCTAssertNil(store.clear())
                store.setEnabled(true)
                store.add([.text("new generation")])
                gate.open()
                await clear?.value
                XCTAssertEqual(probe.count(queued.path!), 0)
                XCTAssertTrue(store.items.contains { $0.id == queued.id })
                XCTAssertEqual(store.items.contains { $0.id == first.id }, fail)
                XCTAssertEqual(store.removalFailures.contains(first.id), fail)
                XCTAssertTrue(store.items.contains { $0.textValue == "new generation" })
                XCTAssertTrue(store.removingItemIDs.isEmpty)
            }, blockingName: "first", gate: gate)
        }
    }

    func testExpiryRechecksRetentionAndProtectsPinnedAndOriginalFiles() async throws {
        let gate = TransferTestGate(started: expectation(description: "expired cleanup in progress"))
        try await withStore({ store, root, _, probe in
            let first = try owned(root, "first", ageDays: 3)
            let queued = try owned(root, "queued", ageDays: 3)
            let pinned = try owned(root, "pinned", pinned: true, ageDays: 3)
            let recent = try owned(root, "recent")
            let original = root.appendingPathComponent("original.txt")
            try Data("keep".utf8).write(to: original)
            let reference = ShelfItem(kind: .file, displayName: "original", path: original.path,
                                      addedAt: Date().addingTimeInterval(-3 * 86400))
            store.add([first, queued, pinned, recent, reference])
            store.retentionDays = 1
            await fulfillment(of: [gate.started], timeout: 3)
            store.retentionDays = 0
            gate.open()
            await waitForIdle(store)
            XCTAssertEqual(Set(store.items.map(\.id)), [queued.id, pinned.id, recent.id])
            XCTAssertEqual(probe.count(queued.path!), 0)
            XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
            store.retentionDays = 1
            await waitForIdle(store)
            XCTAssertEqual(Set(store.items.map(\.id)), [pinned.id, recent.id])
            XCTAssertEqual(probe.count(pinned.path!), 0)
            XCTAssertEqual(probe.count(recent.path!), 0)
        }, blockingName: "first", gate: gate)
    }
}
