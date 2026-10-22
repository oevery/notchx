import Foundation

enum ShelfFileOwnership: String, Codable {
    case reference, managedCopy
}

enum ShelfFileError: Error {
    case unsafeDestination, missingSource
}

/// Injectable filesystem boundary for deterministic in-flight transfer tests.
struct ShelfFileOperations: Sendable {
    var copy: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    var remove: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
    static let live = ShelfFileOperations()
}

/// Owns only files beneath its root. Removing a reference can never delete its source.
struct ShelfFileStorage: Sendable {
    let root: URL
    var operations: ShelfFileOperations = .live

    static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchX/ShelfFiles", isDirectory: true)
    }

    static var legacyImageRoots: [URL] {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Other apps' paths remain references: migration must never delete their data.
        return [support.appendingPathComponent("NotchX/ShelfImages", isDirectory: true)]
    }

    func owns(_ url: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let parent = url.standardizedFileURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        return parent == rootPath || parent.hasPrefix(rootPath + "/")
    }

    func copyIn(_ source: URL) throws -> URL {
        let fm = FileManager.default
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard fm.fileExists(atPath: source.path) else { throw ShelfFileError.missingSource }
        let sourcePath = source.standardizedFileURL.resolvingSymlinksInPath().path
        let destinationPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard sourcePath != destinationPath, !destinationPath.hasPrefix(sourcePath + "/") else {
            throw ShelfFileError.unsafeDestination
        }
        let bucket = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try fm.createDirectory(at: bucket, withIntermediateDirectories: true)
            let target = bucket.appendingPathComponent(source.lastPathComponent)
            try operations.copy(source, target)
            return target
        } catch {
            try? operations.remove(bucket)
            throw error
        }
    }

    @discardableResult
    func removeOwned(_ url: URL) -> Bool {
        guard owns(url) else { return false }
        let fm = FileManager.default
        do { try operations.remove(url) }
        catch {
            // Missing files are already removed; permission/I/O failures
            // must remain failures, including when fileExists cannot inspect them.
            guard let missing = error as? CocoaError,
                  missing.code == .fileNoSuchFile || missing.code == .fileReadNoSuchFile,
                  !fm.fileExists(atPath: url.path) else { return false }
        }
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL != root.standardizedFileURL,
           (try? fm.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
            try? operations.remove(parent)
        }
        return true
    }

}

/// Idempotent release is shared by completion, cancellation and deinitialization.
final class ShelfExportLease: @unchecked Sendable {
    private let lock = NSLock()
    private var onRelease: (() -> Void)?
    init(release: @escaping () -> Void) { onRelease = release }
    func release() {
        lock.lock()
        let action = onRelease
        onRelease = nil
        lock.unlock()
        action?()
    }
    deinit { release() }
}

final class ShelfExportCache: @unchecked Sendable {
    let root: URL
    let sessionRoot: URL
    private let lock = NSLock()
    private var active: [String: Int] = [:]
    private var releasedAt: [String: Date] = [:]
    private var deleting: Set<String> = []
    private let metadataQueue = DispatchQueue(label: "app.notchx.export-metadata")
    private let now: @Sendable () -> Date
    private let retention: TimeInterval
    private let operations: ShelfFileOperations

    init(root: URL, retention: TimeInterval = 24 * 60 * 60,
         now: @escaping @Sendable () -> Date = { Date() },
         operations: ShelfFileOperations = .live) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.sessionRoot = self.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        self.retention = retention
        self.now = now
        self.operations = operations
    }

    func copy(_ source: URL) throws -> URL {
        let result = try copyRetained(source)
        result.lease.release()
        return result.url
    }

    /// A copy is protected before filesystem work starts and remains protected
    /// through handoff; there is no unleased gap between copying and adoption.
    func copyRetained(_ source: URL) throws -> (url: URL, lease: ShelfExportLease) {
        cleanup()
        let batch = sessionRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard let lease = retainBatch(batch) else { throw ShelfFileError.unsafeDestination }
        do {
            let url = try ShelfFileStorage(root: batch, operations: operations).copyIn(source)
            return (url, lease)
        } catch {
            try? operations.remove(batch)
            lease.release()
            throw error
        }
    }

    func retain(_ url: URL) -> ShelfExportLease? {
        guard let batch = batchURL(for: url), let lease = retainBatch(batch) else { return nil }
        // Check after acquiring protection: cleanup cannot delete a retained
        // batch, and a completed deletion cannot produce a lease to a missing file.
        guard FileManager.default.fileExists(atPath: url.path) else { lease.release(); return nil }
        return lease
    }

    func discard(_ url: URL) {
        guard let batch = batchURL(for: url) else { return }
        let key = batch.standardizedFileURL.path
        lock.lock()
        let reserved = active[key] == nil && !deleting.contains(key)
        if reserved { deleting.insert(key) }
        lock.unlock()
        guard reserved else { return }
        // Cancellation must not synchronously delete a large directory on the UI thread.
        metadataQueue.async { [self] in
            var removed = false
            do { try operations.remove(batch); removed = true } catch {}
            lock.lock()
            deleting.remove(key)
            if removed { releasedAt.removeValue(forKey: key) }
            lock.unlock()
        }
    }

    private func batchURL(for url: URL) -> URL? {
        let path = url.standardizedFileURL.path
        let prefix = sessionRoot.path + "/"
        guard path.hasPrefix(prefix), let first = path.dropFirst(prefix.count).split(separator: "/").first,
              UUID(uuidString: String(first)) != nil else { return nil }
        return sessionRoot.appendingPathComponent(String(first), isDirectory: true)
    }

    private func retainBatch(_ batch: URL) -> ShelfExportLease? {
        let key = batch.standardizedFileURL.path
        lock.lock()
        guard !deleting.contains(key) else { lock.unlock(); return nil }
        active[key, default: 0] += 1
        lock.unlock()
        return ShelfExportLease { [self] in
            let date = now()
            lock.lock()
            let count = (active[key] ?? 1) - 1
            if count == 0 {
                releasedAt[key] = date
                active.removeValue(forKey: key)
            } else { active[key] = count }
            lock.unlock()
            guard count == 0 else { return }
            // Metadata writes are outside the state lock and off the caller's
            // thread. The in-memory timestamp protects against stale disk scans.
            metadataQueue.async { [self] in
                lock.lock()
                let latest = releasedAt[key]
                lock.unlock()
                if let latest { try? FileManager.default.setAttributes([.modificationDate: latest], ofItemAtPath: batch.path) }
            }
        }
    }

    func cleanup() {
        let fm = FileManager.default
        let cutoff = now().addingTimeInterval(-retention)
        let sessions = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
        for session in sessions {
            guard UUID(uuidString: session.lastPathComponent) != nil,
                  (try? session.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else { continue }
            let batches = (try? fm.contentsOfDirectory(at: session, includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey])) ?? []
            for batch in batches {
                guard UUID(uuidString: batch.lastPathComponent) != nil,
                      let values = try? batch.resourceValues(forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]),
                      values.isSymbolicLink == false, let modified = values.contentModificationDate else { continue }
                let key = batch.standardizedFileURL.path
                lock.lock()
                let expired = max(modified, releasedAt[key] ?? modified) < cutoff
                let reserved = expired && active[key] == nil && !deleting.contains(key)
                if reserved { deleting.insert(key) }
                lock.unlock()
                guard reserved else { continue }
                // Slow traversal/deletion never holds the lease state lock.
                var removed = false
                do { try operations.remove(batch); removed = true } catch {}
                lock.lock()
                deleting.remove(key)
                if removed { releasedAt.removeValue(forKey: key) }
                lock.unlock()
            }
            if session.standardizedFileURL.path != sessionRoot.path,
               (try? fm.contentsOfDirectory(atPath: session.path).isEmpty) == true {
                try? operations.remove(session)
            }
        }
    }
}

enum ShelfExportStorage {
    static let cache = ShelfExportCache(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("NotchX-ShelfExports", isDirectory: true))
    static var sessionRoot: URL { cache.sessionRoot }
    static func copy(_ source: URL) throws -> URL { try cache.copy(source) }
}

enum ShelfImportStatus: Equatable {
    case waiting, importing, added, duplicate, failed, cancelled, ready
}

struct ShelfImportResult: Identifiable {
    let id: UUID
    let batchID: UUID
    let name: String
    var status: ShelfImportStatus
}
