import AppKit
import UniformTypeIdentifiers
import XCTest
@testable import NotchX

@MainActor
final class ShelfTransferTests: XCTestCase {
    private func withStore(fileOperations: ShelfFileOperations = .live, _ body: (ShelfStore, URL, UserDefaults) async throws -> Void) async throws {
        let domain = "app.notchx.tests.shelf.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let exports = ShelfExportCoordinator(cache: ShelfExportCache(root: root.appendingPathComponent("exports")))
        let store = ShelfStore(preferences: preferences, managedRoot: root.appendingPathComponent("managed"),
                               fileOperations: fileOperations, exports: exports)
        store.setEnabled(true)
        defer {
            store.setEnabled(false)
            preferences.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(store, root, preferences)
    }

    func testReferenceRemovalAndSavedCopyNeverDeleteOriginal() async throws {
        try await withStore { store, root, preferences in
            let original = root.appendingPathComponent("original.pdf")
            try Data("document".utf8).write(to: original)
            let reference = ShelfItem.file(from: original)
            store.add([reference])
            store.remove(reference)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
            store.add([reference])
            await store.saveCopy(reference)?.value
            let copy = try XCTUnwrap(store.items.first)
            XCTAssertEqual(copy.id, reference.id)
            XCTAssertEqual(copy.ownership, .managedCopy)
            let savedURL = try XCTUnwrap(copy.resolvedFileURL)
            XCTAssertNotEqual(savedURL, original)
            XCTAssertEqual(try Data(contentsOf: savedURL), Data("document".utf8))
            let reopened = ShelfStore(preferences: preferences, managedRoot: root.appendingPathComponent("managed"))
            XCTAssertEqual(reopened.items.first?.ownership, .managedCopy)
            // A stale reference snapshot must still remove the current owned copy.
            await store.remove(reference)?.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: savedURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        }
    }

    func testSavingCopyPreservesChangesMadeAfterTheOperationStarts() async throws {
        try await withStore { store, root, preferences in
            let source = root.appendingPathComponent("original.txt")
            try Data("content".utf8).write(to: source)
            let item = ShelfItem.file(from: source)
            store.add([item])
            let save = store.saveCopy(item)
            store.togglePinned(item)
            let accessedAt = store.items[0].lastAccessedAt
            await save?.value
            XCTAssertTrue(store.items[0].isPinned)
            XCTAssertEqual(store.items[0].lastAccessedAt, accessedAt)
            XCTAssertEqual(store.items[0].ownership, .managedCopy)
            let reopened = ShelfStore(preferences: preferences, managedRoot: root.appendingPathComponent("managed"))
            XCTAssertTrue(try XCTUnwrap(reopened.items.first).isPinned)
        }
    }

    func testRemovingItemDuringCopyDoesNotResurrectItOrLeakManagedFiles() async throws {
        try await withStore { store, root, _ in
            let source = root.appendingPathComponent("original.txt")
            try Data("content".utf8).write(to: source)
            let item = ShelfItem.file(from: source)
            store.add([item])
            let save = store.saveCopy(item)
            store.remove(item)
            await save?.value
            XCTAssertTrue(store.items.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("managed").path), [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testExportCacheExpiresCurrentAndPreviousBatchesButPreservesActiveLeases() async throws {
        try await withStore { _, root, _ in
            let clock = ExportTestClock()
            let exports = root.appendingPathComponent("exports")
            let previous = ShelfExportCache(root: exports, retention: 60, now: { clock.date })
            let source = root.appendingPathComponent("original.txt")
            try Data("content".utf8).write(to: source)
            let old = try previous.copy(source)
            let cache = ShelfExportCache(root: exports, retention: 60, now: { clock.date })
            let current = try cache.copy(source)
            let held = try cache.copy(source)
            var lease = cache.retain(held)
            XCTAssertNotNil(lease)
            clock.date.addTimeInterval(61)
            cache.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path))
            lease = nil
            cache.cleanup()
            XCTAssertTrue(FileManager.default.fileExists(atPath: held.path), "Release must restart the retention period")
            clock.date.addTimeInterval(61)
            cache.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: held.path))
            XCTAssertEqual(try Data(contentsOf: source), Data("content".utf8))
        }
    }

    func testStateChangesAndCancellationWhileFilesystemCopyIsInFlight() async throws {
        for scenario in ["pin", "remove", "disable", "cancel"] {
            let gate = TransferTestGate(started: expectation(description: "copy in progress: \(scenario)"))
            defer { gate.open() }
            var operations = ShelfFileOperations.live
            operations.copy = { source, target in
                try FileManager.default.copyItem(at: source, to: target)
                gate.pause()
            }
            try await withStore(fileOperations: operations) { store, root, _ in
                let source = root.appendingPathComponent("original.txt")
                try Data("original".utf8).write(to: source)
                let item = ShelfItem.file(from: source)
                store.add([item])
                let task = try XCTUnwrap(store.saveCopy(item))
                await fulfillment(of: [gate.started], timeout: 3)
                switch scenario {
                case "pin": store.togglePinned(item)
                case "remove": store.remove(item)
                case "disable": store.setEnabled(false); store.setEnabled(true)
                default: task.cancel()
                }
                gate.open()
                await task.value
                if scenario == "pin" {
                    XCTAssertTrue(try XCTUnwrap(store.items.first).isPinned)
                    XCTAssertEqual(store.items.first?.ownership, .managedCopy)
                } else {
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("managed").path), [])
                    if scenario == "remove" { XCTAssertTrue(store.items.isEmpty) }
                    else { XCTAssertEqual(store.items.first?.ownership, .reference) }
                }
                XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
            }
        }
    }

    func testPromisedPDFIsCopiedBeforeProviderFileDisappearsAndExportsIndependently() async throws {
        try await withStore { store, root, _ in
            let original = root.appendingPathComponent("attachment.pdf")
            try Data("attachment".utf8).write(to: original)
            let provider = NSItemProvider()
            provider.suggestedName = "attachment.pdf"
            provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
                completion(original, false, nil)
                return nil
            }
            let added = await withCheckedContinuation { continuation in
                _ = store.handleDrop(providers: [provider]) { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(added, 1)
            XCTAssertEqual(store.importResults.map(\.status), [.added])
            try FileManager.default.removeItem(at: original)
            let saved = try XCTUnwrap(store.items.first)
            let savedURL = try XCTUnwrap(saved.resolvedFileURL)
            XCTAssertEqual(saved.ownership, .managedCopy)
            XCTAssertEqual(try Data(contentsOf: savedURL), Data("attachment".utf8))
            let exported = store.dragProvider(for: saved)
            let exportData: Data? = await withCheckedContinuation { continuation in
                _ = exported.loadFileRepresentation(forTypeIdentifier: UTType.pdf.identifier) { url, _ in
                    let data = url.flatMap { try? Data(contentsOf: $0) }
                    if let url { try? FileManager.default.removeItem(at: url) }
                    continuation.resume(returning: data)
                }
            }
            XCTAssertEqual(exportData, Data("attachment".utf8))
            XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        }
    }

    func testMixedImportReportsAddedDuplicateAndFailure() async throws {
        try await withStore { store, _, _ in
            let missing = NSItemProvider(object: URL(fileURLWithPath: "/notchx-nonexistent/absent.pdf") as NSURL)
            let providers = [NSItemProvider(object: "snippet" as NSString), NSItemProvider(object: "snippet" as NSString), NSItemProvider(), missing]
            let added = await withCheckedContinuation { continuation in
                _ = store.handleDrop(providers: providers) { continuation.resume(returning: $0) }
            }
            XCTAssertEqual(added, 1)
            XCTAssertEqual(store.items.count, 1)
            XCTAssertEqual(store.importResults.map(\.status), [.added, .duplicate, .failed, .failed])
        }
    }

    func testDisableDuringProviderLoadRejectsLateFileAndKeepsCompletedItems() async throws {
        try await withStore { store, root, _ in
            store.add([.text("already stored")])
            let original = root.appendingPathComponent("late.pdf")
            try Data("late".utf8).write(to: original)
            let gate = ProviderGate()
            let started = expectation(description: "provider requested")
            let completedURL = root.appendingPathComponent("completed.pdf")
            try Data("completed".utf8).write(to: completedURL)
            let completedProvider = NSItemProvider()
            completedProvider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
                completion(completedURL, false, nil)
                return nil
            }
            let provider = NSItemProvider()
            provider.registerFileRepresentation(forTypeIdentifier: UTType.pdf.identifier, fileOptions: [], visibility: .all) { completion in
                gate.set { completion(original, false, nil) }
                started.fulfill()
                return Progress(totalUnitCount: 1)
            }
            _ = store.handleDrop(providers: [completedProvider, provider])
            await fulfillment(of: [started], timeout: 3)
            store.setEnabled(false)
            gate.deliver()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(store.items.count, 2)
            XCTAssertEqual(store.items.first?.textValue, "already stored")
            let completedCopy = try XCTUnwrap(store.items.last?.resolvedFileURL)
            XCTAssertEqual(try Data(contentsOf: completedCopy), Data("completed".utf8))
            XCTAssertEqual(store.importResults.map(\.status), [.added, .cancelled])
            XCTAssertFalse(store.canRetryImport(store.importResults[1]))
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("managed").path)) ?? []
            XCTAssertEqual(files.count, 1)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        }
    }

    func testLegacyOwnershipDoesNotAdoptAnotherApplicationsFiles() throws {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        func decode(_ app: String) throws -> ShelfItem {
            let raw: [String: Any] = ["kind": "image", "displayName": "old.png",
                                      "path": support.appendingPathComponent(app + "/ShelfImages/old.png").path]
            return try JSONDecoder().decode(ShelfItem.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        XCTAssertEqual(try decode("SuperIsland").ownership, .reference)
        XCTAssertEqual(try decode("NotchX").ownership, .managedCopy)
    }

    func testOwnedCleanupRejectsExternalFilesAndSymlinkEscapes() async throws {
        try await withStore { _, root, _ in
            let storage = ShelfFileStorage(root: root.appendingPathComponent("managed"))
            let external = root.appendingPathComponent("outside")
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let file = external.appendingPathComponent("keep.pdf")
            try Data([1]).write(to: file)
            try FileManager.default.createDirectory(at: storage.root, withIntermediateDirectories: true)
            let link = storage.root.appendingPathComponent("escape")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            XCTAssertFalse(storage.removeOwned(file))
            XCTAssertFalse(storage.removeOwned(link.appendingPathComponent("keep.pdf")))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            XCTAssertThrowsError(try storage.copyIn(root))
        }
    }
}

private final class ProviderGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (() -> Void)?
    func set(_ callback: @escaping () -> Void) { lock.lock(); self.callback = callback; lock.unlock() }
    func deliver() { lock.lock(); let action = callback; callback = nil; lock.unlock(); action?() }
}

private final class ExportTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = Date()
    var date: Date {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
