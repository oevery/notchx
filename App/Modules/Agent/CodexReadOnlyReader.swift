import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
#if canImport(SQLite3)
import SQLite3
#endif

struct CodexReadOnlySnapshot: Sendable {
    let connection: AgentSourceConnection
    var events: [AgentSessionEvent] = []
}

/// All filesystem and SQLite I/O runs on this actor, never the main actor.
/// Storage is an undocumented compatibility boundary: fail closed on changes.
actor CodexReadOnlyReader {
    static let maximumSessions = 40
    static let maximumDatabaseBytes: UInt64 = 128 * 1024 * 1024
    private let root: URL
    private var sequence: Int64 = 0
    private var previousEvents: [String: AgentSessionEvent] = [:]

    init(root: URL) { self.root = root }

    func snapshot() -> CodexReadOnlySnapshot {
        guard !Task.isCancelled else { return .init(connection: .disconnected) }
        do {
            return try readSnapshot()
        } catch let error as NSError {
            let denied = (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError)
                || (error.domain == NSPOSIXErrorDomain && (error.code == 1 || error.code == 13))
            return .init(connection: denied ? .permissionDenied : .disconnected)
        }
    }

    /// Resolving every candidate rejects symlink escapes. Only the selected
    /// metadata catalog and its SQLite sidecars below .codex are considered.
    func containedURL(_ url: URL) -> URL? {
        guard let canonicalRoot = canonicalExistingURL(root),
              let candidate = canonicalExistingURL(url) else { return nil }
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard candidate.path.hasPrefix(prefix), candidate != canonicalRoot else { return nil }
        return candidate
    }

    private func canonicalExistingURL(_ url: URL) -> URL? {
        // Foundation on Darwin deliberately shortens /private/var to /var,
        // reintroducing a symlink that SQLite's NOFOLLOW correctly rejects.
        // POSIX realpath preserves the actual filesystem path. Resolve both
        // sides of the boundary, and keep NOFOLLOW on the subsequent open.
        guard url.isFileURL, let path = url.path.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    private func readSnapshot() throws -> CodexReadOnlySnapshot {
#if canImport(SQLite3)
        return try readDatabase()
#else
        return .init(connection: .unsupportedSchema)
#endif
    }
}

#if canImport(SQLite3)
extension CodexReadOnlyReader {
    private func readDatabase() throws -> CodexReadOnlySnapshot {
        // Compatibility gate: only the catalog shape observed in Desktop
        // 26.1013.40934 is supported. No fallback to inaccessible state databases,
        // transcript directories, configuration files, sockets or credentials.
        let databaseURL = root.appendingPathComponent("sqlite/codex-dev.db")
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return .init(connection: .disconnected)
        }
        guard let databaseURL = containedURL(databaseURL) else { return .init(connection: .unsupportedSchema) }
        let attributes = try FileManager.default.attributesOfItem(atPath: databaseURL.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size <= Self.maximumDatabaseBytes else { return .init(connection: .unsupportedSchema) }
        guard FileManager.default.isReadableFile(atPath: databaseURL.path) else {
            return .init(connection: .permissionDenied)
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: databaseURL.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path), containedURL(sidecar) == nil {
                return .init(connection: .unsupportedSchema)
            }
        }
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard opened == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return .init(connection: opened == SQLITE_PERM || opened == SQLITE_AUTH ? .permissionDenied : .disconnected)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 100)
        // Connection-local protections; no schema, journaling or config writes.
        guard sqlite3_exec(db, "PRAGMA query_only=ON; PRAGMA trusted_schema=OFF; PRAGMA cache_size=-256; PRAGMA mmap_size=0;", nil, nil, nil) == SQLITE_OK else {
            return .init(connection: .unsupportedSchema)
        }
        var progressSteps = 0
        return withUnsafeMutablePointer(to: &progressSteps) { steps in
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                let steps = context.assumingMemoryBound(to: Int.self)
                steps.pointee += 1
                return steps.pointee > 500 ? 1 : 0
            }, steps)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            return databaseSnapshot(db)
        }
    }

    private func databaseSnapshot(_ db: OpaquePointer) -> CodexReadOnlySnapshot {
        guard let columns = tableColumns("local_thread_catalog", db: db),
              Set(["thread_id", "source_kind", "thread_source", "source_updated_at", "display_title", "missing_candidate", "host_id"]).isSubset(of: columns) else {
            return .init(connection: .unsupportedSchema)
        }
        // This catalog tags local user sessions; it does NOT establish which
        // client created them, nor distinguish every internal session. Transport
        // names are not Desktop provenance. Runtime activity remains unknown.
        let sql = "SELECT substr(thread_id,1,200), source_updated_at, substr(display_title,1,160) FROM local_thread_catalog WHERE source_kind IN ('chatgpt','vscode') AND thread_source='user' AND missing_candidate=0 AND typeof(source_updated_at) IN ('real','integer') ORDER BY source_updated_at DESC LIMIT \(Self.maximumSessions)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return .init(connection: .unsupportedSchema)
        }
        defer { sqlite3_finalize(statement) }
        var events: [AgentSessionEvent] = []
        var seen: Set<String> = []
        while true {
            guard !Task.isCancelled else { return .init(connection: .disconnected) }
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { return .init(connection: .disconnected) }
            let threadID = columnText(statement, 0)
            guard !threadID.isEmpty, threadID.count < 200,
                  AgentVerifiedNavigationTarget(desktopThreadID: threadID).url != nil else { continue }
            let seconds = sqlite3_column_double(statement, 1)
            guard seconds.isFinite, seconds >= 0, seconds <= 253_402_300_799,
                  seen.insert(threadID).inserted else { continue }
            let modified = Date(timeIntervalSince1970: seconds)
            let metadataTitle = columnText(statement, 2)
            let title = metadataTitle.isEmpty ? threadID : metadataTitle
            if let previous = previousEvents[threadID], previous.updatedAt == modified, previous.title == title {
                events.append(previous)
                continue
            }
            sequence += 1
            let id = AgentSessionID(providerID: "codex.local.catalog", sessionID: threadID)
            events.append(AgentSessionEvent(id: id, runID: nil, requestID: nil,
                eventID: "catalog-\(sequence)", sequence: sequence, parentID: nil,
                classification: .userSession, status: .unknown,
                title: title, summary: nil, updatedAt: modified))
        }
        previousEvents = Dictionary(uniqueKeysWithValues: events.map { ($0.id.sessionID, $0) })
        return .init(connection: .connected, events: events)
    }

    private func tableColumns(_ table: String, db: OpaquePointer) -> Set<String>? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var columns: Set<String> = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return columns }
            guard result == SQLITE_ROW, columns.count < 100 else { return nil }
            columns.insert(columnText(statement, 1))
        }
    }

    private func columnText(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }
}
#endif
