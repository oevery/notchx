import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#endif
#if canImport(Darwin)
import Darwin
#endif
@testable import NotchX

final class CodexReadOnlySourceTests: XCTestCase {
    private var fixtures: CodexCatalogFixtures!

    override func setUpWithError() throws {
        fixtures = try CodexCatalogFixtures()
    }

    override func tearDownWithError() throws {
        if let fixtures { try fixtures.verifyReadOnly() }
        fixtures = nil
    }

    private func snapshot(_ name: String) -> CodexReadOnlySnapshot {
        let reader = CodexReadOnlyReader(root: fixtures.root.appendingPathComponent(name))
        let finished = expectation(description: "Off-main actor catalog snapshot")
        var result = CodexReadOnlySnapshot(connection: .disconnected)
        Task.detached {
            result = await reader.snapshot()
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        return result
    }

    func testMissingCatalogDoesNotClaimConnection() {
        let result = snapshot("missing")
#if canImport(SQLite3)
        XCTAssertEqual(result.connection, .disconnected)
#else
        XCTAssertEqual(result.connection, .unsupportedSchema)
#endif
        XCTAssertTrue(result.events.isEmpty)
    }

    func testUnknownSchemaFailsClosed() {
        for fixture in ["unsupported", "malformed"] {
            let result = snapshot(fixture)
            XCTAssertEqual(result.connection, .unsupportedSchema)
            XCTAssertTrue(result.events.isEmpty)
        }
    }

    func testCatalogSymlinkEscapeRejected() {
#if canImport(Darwin)
        let fixtureURL = fixtures.root.appendingPathComponent("catalog/sqlite/codex-dev.db")
        let reader = CodexReadOnlyReader(root: fixtures.root.appendingPathComponent("catalog"))
        let finished = expectation(description: "Darwin physical path canonicalization")
        var canonicalPath: String?
        Task.detached {
            canonicalPath = await reader.containedURL(fixtureURL)?.path
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        // The native temp path is usually /var/...; Foundation may retain that
        // symlink spelling. The production boundary must use physical realpath.
        guard let physical = fixtureURL.path.withCString({ realpath($0, nil) }) else {
            XCTFail("Synthetic catalog should have a physical path")
            return
        }
        defer { free(physical) }
        XCTAssertEqual(canonicalPath, String(cString: physical))
#endif
        let result = snapshot("escape")
        XCTAssertEqual(result.connection, .unsupportedSchema)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testOnlySupportedUserTaggedMetadataAppearsAndDeduplicates() {
        let result = snapshot("catalog")
#if canImport(SQLite3)
        XCTAssertEqual(result.connection, .connected)
        XCTAssertEqual(Set(result.events.map(\.id.sessionID)), ["thread-user-1", "thread-user-2", "local-vscode-user"])
        XCTAssertEqual(result.events.count, 3)
        // Invalid newer duplicate timestamps must not suppress valid metadata.
        XCTAssertEqual(result.events.first(where: { $0.id.sessionID == "thread-user-1" })?.updatedAt.timeIntervalSince1970, 1_792_238_400)
        XCTAssertTrue(result.events.allSatisfy { $0.status == .unknown && $0.summary == nil && $0.runID == nil && $0.requestID == nil && $0.parentID == nil })
        XCTAssertTrue(result.events.allSatisfy { $0.classification == .userSession })
        XCTAssertTrue(result.events.allSatisfy { $0.title.hasPrefix("Metadata title") })
        XCTAssertEqual(result.events.first(where: { $0.id.sessionID == "local-vscode-user" })?.updatedAt.timeIntervalSince1970, 1_792_238_100.125)
#else
        XCTAssertEqual(result.connection, .unsupportedSchema)
#endif
    }

    func testUnchangedCatalogReusesEventSequence() {
#if canImport(SQLite3)
        let reader = CodexReadOnlyReader(root: fixtures.root.appendingPathComponent("catalog"))
        let finished = expectation(description: "Repeated local snapshot")
        var sequences: [[Int64]] = []
        Task.detached {
            let first = await reader.snapshot()
            let second = await reader.snapshot()
            sequences = [first.events.map(\.sequence), second.events.map(\.sequence)]
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(sequences.count, 2)
        XCTAssertEqual(sequences.first, sequences.last)
#endif
    }

    func testSnapshotBoundedToFortyRows() {
        let result = snapshot("many")
#if canImport(SQLite3)
        XCTAssertEqual(result.connection, .connected)
        XCTAssertEqual(result.events.count, 40)
#else
        XCTAssertEqual(result.connection, .unsupportedSchema)
#endif
    }

    func testReadOnlyWALSnapshotIncludesCommittedMetadata() {
        let result = snapshot("wal")
#if canImport(SQLite3)
        XCTAssertEqual(result.connection, .connected)
        XCTAssertEqual(Set(result.events.map(\.id.sessionID)), ["thread-wal", "thread-wal-2"])
#else
        XCTAssertEqual(result.connection, .unsupportedSchema)
#endif
    }

    func testSQLiteSidecarSymlinkEscapeRejected() {
        let result = snapshot("sidecar-escape")
        XCTAssertEqual(result.connection, .unsupportedSchema)
        XCTAssertTrue(result.events.isEmpty)
    }
}

/// Native XCTest and the portable harness share these synthetic fixtures. They
/// never depend on the developer's Codex installation or external environment.
private final class CodexCatalogFixtures {
    let root: URL
    private var originals: [URL: Data] = [:]
#if canImport(SQLite3)
    private var walWriter: OpaquePointer?
#endif

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("notchx-codex-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
#if canImport(SQLite3)
        try database("unsupported", sql: "CREATE TABLE unsupported (id TEXT)")
        try database("catalog", sql: Self.schema + """
        INSERT INTO local_thread_catalog VALUES
        ('thread-user-1',1e999,'chatgpt','user','Metadata title 1',0,'fixture-host'),
        ('thread-user-1',1792238400,'chatgpt','user','Metadata title 1',0,'fixture-host'),
        ('thread-user-2',1792238300,'chatgpt','user','Metadata title 2',0,'fixture-host'),
        ('thread-user-1',1792238200,'chatgpt','user','Metadata title old',0,'other-host'),
        ('local-vscode-user',1792238100.125,'vscode','user','Metadata title local',0,'fixture-host'),
        ('unknown-transport',1792238050,'unknown','user','Unknown transport',0,'fixture-host'),
        ('nonfinite-time',1e999,'vscode','user','Nonfinite',0,'fixture-host'),
        ('null-time',NULL,'vscode','user','Null time',0,'fixture-host'),
        ('invalid-time',-1,'vscode','user','Invalid time',0,'fixture-host'),
        ('missing-session',1792238040,'vscode','user','Missing',1,'fixture-host'),
        ('unknown-missing',1792238030,'vscode','user','Unknown missing',NULL,'fixture-host'),
        ('unknown-origin',1792238000,'chatgpt',NULL,'Unknown origin',0,'fixture-host'),
        ('internal-automation',1792237900,'chatgpt','automation','Automation',0,'fixture-host'),
        ('bad/id',1792237800,'chatgpt','user','Bad ID',0,'fixture-host');
        """)
        let rows = (0..<80).map { "('thread-\($0)',\(1792238400 + $0),'chatgpt','user','Metadata title',0,'fixture-host')" }.joined(separator: ",")
        try database("many", sql: Self.schema + "INSERT INTO local_thread_catalog VALUES " + rows + ";")
        try database("sidecar-escape", sql: Self.schema)
        let walURL = try database("wal", sql: Self.schema + "INSERT INTO local_thread_catalog VALUES ('thread-wal',1792238400,'chatgpt','user','Metadata title WAL',0,'fixture-host');")
        guard sqlite3_open_v2(walURL.path, &walWriter, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let walWriter else {
            throw NSError(domain: "CodexFixture", code: 1)
        }
        try execute("PRAGMA journal_mode=WAL; INSERT INTO local_thread_catalog VALUES ('thread-wal-2',1792238401,'chatgpt','user','Metadata title WAL 2',0,'fixture-host');", on: walWriter)
#endif
        let outside = root.appendingPathComponent("outside.db")
        try Data("Not a database".utf8).write(to: outside)
        let malformed = root.appendingPathComponent("malformed/sqlite/codex-dev.db")
        try FileManager.default.createDirectory(at: malformed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Malformed SQLite fixture".utf8).write(to: malformed)
        let escape = root.appendingPathComponent("escape/sqlite/codex-dev.db")
        try FileManager.default.createDirectory(at: escape.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: escape, withDestinationURL: outside)
        let sidecar = root.appendingPathComponent("sidecar-escape/sqlite/codex-dev.db-wal")
        try FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
        if let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let url as URL in files {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                // SQLite may update SHM read locks even for read-only connections.
                if values.isRegularFile == true, values.isSymbolicLink != true, !url.path.hasSuffix("-shm") {
                    originals[url] = try Data(contentsOf: url)
                }
            }
        }
    }

    func verifyReadOnly() throws {
        for (url, data) in originals {
            XCTAssertEqual(try Data(contentsOf: url), data, "Read-only catalog access changed fixture \(url.lastPathComponent)")
        }
    }

    deinit {
#if canImport(SQLite3)
        if let walWriter { sqlite3_close(walWriter) }
#endif
        try? FileManager.default.removeItem(at: root)
    }

#if canImport(SQLite3)
    private static let schema = "CREATE TABLE local_thread_catalog (thread_id TEXT, source_updated_at REAL, source_kind TEXT, thread_source TEXT, display_title TEXT, missing_candidate INTEGER, host_id TEXT);"

    @discardableResult
    private func database(_ name: String, sql: String) throws -> URL {
        let url = root.appendingPathComponent(name + "/sqlite/codex-dev.db")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            throw NSError(domain: "CodexFixture", code: 2)
        }
        defer { sqlite3_close(database) }
        try execute(sql, on: database)
        return url
    }

    private func execute(_ sql: String, on database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "CodexFixture", code: 3)
        }
    }
#endif
}
