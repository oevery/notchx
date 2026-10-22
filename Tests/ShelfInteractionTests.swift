import AppKit
import XCTest
@testable import NotchX

@MainActor
final class ShelfInteractionTests: XCTestCase {
    func testSelectionRangesTogglesAndSearchReconciliation() {
        let ids = (0..<5).map { _ in UUID() }
        var selection = ShelfSelection()
        selection.select(ids[1], in: ids)
        selection.select(ids[3], in: ids, extending: true)
        XCTAssertEqual(selection.ids, Set(ids[1...3]))
        selection.select(ids[2], in: ids, toggling: true)
        XCTAssertEqual(selection.ids, [ids[1], ids[3]])
        selection.reconcile([ids[0], ids[3]])
        XCTAssertEqual(selection.ids, [ids[3]])
        selection.move(-1, in: [ids[0], ids[3]], extending: false)
        XCTAssertEqual(selection.ids, [ids[0]])
        selection.move(1, in: [ids[0], ids[3]], extending: true)
        XCTAssertEqual(selection.ids, [ids[0], ids[3]])
        selection.clear()
        selection.move(1, in: ids, extending: true)
        XCTAssertEqual(selection.ids, [ids[0]])
    }

    private func withStore(_ body: (ShelfStore, UserDefaults, URL) async throws -> Void) async throws {
        let domain = "app.notchx.tests.interactions.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: domain)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let exports = ShelfExportCoordinator(cache: ShelfExportCache(root: root.appendingPathComponent("exports")))
        let store = ShelfStore(preferences: preferences, managedRoot: root, exports: exports)
        store.setEnabled(true)
        defer {
            store.setEnabled(false)
            preferences.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        try await body(store, preferences, root)
    }

    func testUndoKeepsManagedCopyAndOriginalAndCoalescesRepeatedRemoval() async throws {
        try await withStore { store, _, root in
            let url = root.appendingPathComponent("copy.txt")
            try Data("keep".utf8).write(to: url)
            let managed = ShelfItem.file(from: url, ownership: .managedCopy)
            let text = ShelfItem.text("text")
            store.add([managed, text])
            let now = Date()
            store.requestRemoval([managed], now: now)
            store.requestRemoval([text, managed], now: now)
            XCTAssertTrue(store.visibleItems.isEmpty)
            XCTAssertEqual(store.pendingRemoval?.itemIDs.count, 2)
            XCTAssertNil(store.commitPendingRemoval(now: now.addingTimeInterval(9)))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            store.undoRemoval()
            XCTAssertEqual(store.visibleItems.map(\.id), [managed.id, text.id])
            XCTAssertNil(store.commitPendingRemoval(now: now.addingTimeInterval(11)))
            XCTAssertEqual(try Data(contentsOf: url), Data("keep".utf8))
        }
    }

    func testPendingRemovalSurvivesRestartAndExpiresThroughOwnedQueue() async throws {
        try await withStore { store, preferences, root in
            let url = root.appendingPathComponent("owned.txt")
            try Data("owned".utf8).write(to: url)
            let original = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
            try Data("original".utf8).write(to: original)
            defer { try? FileManager.default.removeItem(at: original) }
            let owned = ShelfItem.file(from: url, ownership: .managedCopy)
            let reference = ShelfItem.file(from: original)
            store.add([owned, reference])
            let now = Date()
            store.requestRemoval([owned, reference], now: now)
            let reopened = ShelfStore(preferences: preferences, managedRoot: root)
            reopened.setEnabled(true)
            defer { reopened.setEnabled(false) }
            XCTAssertTrue(reopened.visibleItems.isEmpty)
            await reopened.commitPendingRemoval(now: now.addingTimeInterval(11))?.value
            XCTAssertTrue(reopened.items.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        }
    }

    func testDisableCancelsUndoDeadlineWithoutDeletingOrLosingItems() async throws {
        try await withStore { store, preferences, root in
            let item = ShelfItem.text("preserve")
            store.add([item])
            store.requestRemoval([item])
            store.setEnabled(false)
            XCTAssertNil(store.pendingRemoval)
            XCTAssertNil(store.commitPendingRemoval(now: .distantFuture))
            let reopened = ShelfStore(preferences: preferences, managedRoot: root)
            XCTAssertEqual(reopened.visibleItems.map(\.id), [item.id])
            XCTAssertNil(reopened.pendingRemoval)
        }
    }

    func testPinChangedDuringUndoWindowProtectsItemAtExpiry() async throws {
        try await withStore { store, _, _ in
            let item = ShelfItem.text("pin while pending")
            store.add([item])
            let now = Date()
            store.requestRemoval([item], now: now)
            store.togglePinned(item)
            await store.commitPendingRemoval(now: now.addingTimeInterval(11))?.value
            XCTAssertEqual(store.visibleItems.map(\.id), [item.id])
            XCTAssertTrue(try XCTUnwrap(store.visibleItems.first).isPinned)
        }
    }

    func testExplicitPasteImportsMixedFileAndTextWithoutChangingOriginal() async throws {
        try await withStore { store, _, root in
            let source = root.appendingPathComponent("original.txt")
            try Data("original".utf8).write(to: source)
            let pasteboard = NSPasteboard(name: .init("app.notchx.tests.paste.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            XCTAssertTrue(pasteboard.writeObjects([source as NSURL, "A clipboard note" as NSString]))
            let done = expectation(description: "paste imported")
            XCTAssertTrue(store.paste(from: pasteboard) { count in
                XCTAssertEqual(count, 2)
                done.fulfill()
            })
            await fulfillment(of: [done], timeout: 3)
            XCTAssertEqual(store.items.count, 2)
            XCTAssertTrue(store.items.contains { $0.textValue == "A clipboard note" })
            XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
            await store.clear()?.value
            XCTAssertEqual(try Data(contentsOf: source), Data("original".utf8))
        }
    }

    func testPasteLoadsOnlyTheChosenSupportedRepresentation() async throws {
        try await withStore { store, _, _ in
            let pasteboard = NSPasteboard(name: .init("app.notchx.tests.lazy-paste.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let producer = ShelfClipboardProducer()
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setDataProvider(producer, forTypes: [.string, .pdf, ShelfClipboardProducer.unsupported]))
            XCTAssertTrue(pasteboard.writeObjects([item]))
            producer.resetRequests()
            let done = expectation(description: "supported clipboard note imported")
            XCTAssertTrue(store.paste(from: pasteboard) { count in
                XCTAssertEqual(count, 1)
                done.fulfill()
            })
            await fulfillment(of: [done], timeout: 3)
            XCTAssertEqual(store.items.first?.textValue, "Clipboard note")
            XCTAssertFalse(producer.requests.contains(.pdf), "An unchosen supported format must remain lazy")
            XCTAssertFalse(producer.requests.contains(ShelfClipboardProducer.unsupported))
        }
    }

    func testUnsupportedClipboardReturnsWithoutRequestingData() async throws {
        try await withStore { store, _, _ in
            let pasteboard = NSPasteboard(name: .init("app.notchx.tests.unsupported-paste.\(UUID().uuidString)"))
            defer { pasteboard.releaseGlobally() }
            let producer = ShelfClipboardProducer()
            let item = NSPasteboardItem()
            XCTAssertTrue(item.setDataProvider(producer, forTypes: [ShelfClipboardProducer.unsupported]))
            XCTAssertTrue(pasteboard.writeObjects([item]))
            producer.resetRequests()
            XCTAssertFalse(store.paste(from: pasteboard))
            XCTAssertTrue(producer.requests.isEmpty)
            XCTAssertTrue(store.items.isEmpty)
        }
    }

    func testMixedDragPromisesCopyAndNeverMoveOriginals() async throws {
        try await withStore { _, _, root in
            let source = root.appendingPathComponent("source.txt")
            let destination = root.appendingPathComponent("destination.txt")
            try Data("file".utf8).write(to: source)
            let items = [ShelfItem.file(from: source), .text("text"), .link(URL(string: "https://example.com")!)]
            let writers = ShelfBatchDragView.pasteboardWriters(for: items)
            XCTAssertEqual(writers.count, 3)
            let promise = try XCTUnwrap(writers.first as? ShelfPromisedFile)
            let writer = promise.writer
            let queue = writer.operationQueue(for: promise)
            XCTAssertFalse(queue === OperationQueue.main)
            let done = expectation(description: "promised file copied")
            queue.addOperation {
                writer.write(to: destination) { error in
                    XCTAssertNil(error)
                    done.fulfill()
                }
            }
            await fulfillment(of: [done], timeout: 3)
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: destination))
        }
    }

    func testSingleAndBatchShelfDragsCannotReimportButExternalCopiesStillCan() async throws {
        try await withStore { store, _, root in
            let source = root.appendingPathComponent("source.txt")
            try Data("preserve original".utf8).write(to: source)
            let items = [ShelfItem.file(from: source), .text("drag text"), .link(URL(string: "https://example.com")!)]
            store.add(items)
            for item in items {
                XCTAssertFalse(store.handleDrop(providers: [store.dragProvider(for: item)]))
            }
            // Read the representations actually advertised on the native drag
            // pasteboard, including promised files, without materializing them.
            let pasteboard = NSPasteboard(name: .init("app.notchx.tests.drag-origin.\(UUID())"))
            defer { pasteboard.releaseGlobally() }
            XCTAssertTrue(pasteboard.writeObjects(ShelfBatchDragView.pasteboardWriters(for: items)))
            let providers = try XCTUnwrap(pasteboard.pasteboardItems).map { item in
                let provider = NSItemProvider()
                for type in item.types {
                    provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                        completion(nil, nil) // rejection must not request any representation
                        XCTFail("Internal drag representations must remain lazy")
                        return nil
                    }
                }
                return provider
            }
            XCTAssertEqual(providers.count, 3)
            for provider in providers { XCTAssertFalse(store.handleDrop(providers: [provider])) }
            XCTAssertFalse(store.isImporting)
            XCTAssertTrue(store.importResults.isEmpty)
            XCTAssertEqual(store.items.count, 3)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "preserve original")

            let imported = expectation(description: "external text can still import")
            XCTAssertTrue(store.handleDrop(providers: [NSItemProvider(object: "external" as NSString)]) { _ in imported.fulfill() })
            await fulfillment(of: [imported], timeout: 3)
            XCTAssertTrue(store.items.contains { $0.textValue == "external" })
        }
    }

    func testExplicitRetryIsNotRejectedAsAnInternalRedrop() async throws {
        try await withStore { store, _, _ in
            let unreadable = NSItemProvider()
            unreadable.registerDataRepresentation(forTypeIdentifier: "public.utf8-plain-text", visibility: .all) { completion in
                completion(nil, CocoaError(.fileReadUnknown))
                return nil
            }
            XCTAssertTrue(store.handleAirDropDrop(providers: [ShelfDragOrigin.mark(unreadable)]))
            try await NativeUI.waitFor("unreadable sharing preparation finishes") { !store.isImporting }
            let failed = try XCTUnwrap(store.importResults.first)
            XCTAssertEqual(failed.status, .failed)
            XCTAssertTrue(store.canRetryImport(failed))
            store.retryImport(failed)
            XCTAssertEqual(store.importResults.count, 2, "The explicit retry must start even when its source is an internal drag")
            try await NativeUI.waitFor("retry reports its actual read failure") { !store.isImporting }
            XCTAssertEqual(store.importResults.map(\.status), [.failed, .failed])
            XCTAssertTrue(store.items.isEmpty)
        }
    }
}

/// A clipboard producer is the external boundary. Requests may arrive on
/// NSItemProvider's queue; only the recorded request list is mutable.
private final class ShelfClipboardProducer: NSObject, NSPasteboardItemDataProvider, @unchecked Sendable {
    static let unsupported = NSPasteboard.PasteboardType("app.notchx.tests.unsupported")
    private let lock = NSLock()
    private var recordedRequests: [NSPasteboard.PasteboardType] = []
    var requests: [NSPasteboard.PasteboardType] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }
    func resetRequests() { lock.lock(); recordedRequests.removeAll(); lock.unlock() }
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        lock.lock(); recordedRequests.append(type); lock.unlock()
        if type == .string { item.setString("Clipboard note", forType: type) }
        else { item.setData(Data(repeating: 0, count: 64), forType: type) }
    }
}
