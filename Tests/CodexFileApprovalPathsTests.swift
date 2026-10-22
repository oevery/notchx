import Foundation
import XCTest
@testable import NotchX

final class CodexFileApprovalPathsTests: XCTestCase {
    private let thread = "01a156b9-bfc7-71c1-a986-7ccc73faf51e"
    private let input = "*** Begin Patch\n*** Add File: new.txt\n+private patch contents\n*** Update File: old.txt\n*** Move to: renamed.txt\n@@\n-before\n+after\n*** Delete File: gone.txt\n*** End Patch"

    private func record(_ type: String, _ payload: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: ["type": type, "payload": payload])
        data.append(10); return data
    }

    private func call(turn: String = "turn-a", item: String = "call-a") -> [String: Any] {
        ["type": "custom_tool_call", "name": "apply_patch", "call_id": item, "input": input,
         "internal_chat_message_metadata_passthrough": ["turn_id": turn]]
    }

    func testCompletePatchIncludesEverySourceAndRenameDestinationWithoutPatchText() {
        XCTAssertEqual(CodexFileApprovalPaths.patch(input, cwd: "/work"), ["/work/new.txt", "/work/old.txt", "/work/renamed.txt", "/work/gone.txt"])
        for invalid in [String(input.dropLast()), input.replacingOccurrences(of: "*** Move to:", with: "*** Future:"),
                        input.replacingOccurrences(of: "new.txt", with: "bad\u{0000}.txt"),
                        "*** Begin Patch\n*** End Patch", "*** Begin Patch\n*** Move to: unscoped\n*** End Patch"] {
            XCTAssertNil(CodexFileApprovalPaths.patch(invalid, cwd: "/work"))
        }
        XCTAssertNil(CodexFileApprovalPaths.patch(input, cwd: "relative"))
    }

    func testCanonicalFileChangesRequireKnownKindsAndIncludeMoveDestination() {
        let changes: [[String: Any]] = [["path": "/work/old", "kind": ["type": "update", "move_path": "/other/new"], "diff": "PRIVATE"],
                                      ["path": "/work/add", "kind": ["type": "add"]]]
        XCTAssertEqual(CodexFileApprovalPaths.changes(changes), ["/work/old", "/other/new", "/work/add"])
        let invalidValues: [[[String: Any]]] = [[], [["path": "no-kind"]], [["path": "x", "kind": ["type": "future"]]],
                                        [["path": "x", "kind": ["type": "update", "move_path": 42]]],
                                        [["path": "x", "kind": ["type": "delete", "move_path": "y"]]]]
        for invalid in invalidValues {
            XCTAssertNil(CodexFileApprovalPaths.changes(invalid))
        }
    }

    func testExactTurnAndCallMatchRejectsDuplicatesOutputsAndPartialRecords() throws {
        XCTAssertNil(CodexFileApprovalPaths.records(try record("response_item", call()), discardingFirst: false, turn: "turn-a", item: "call-a"), "Relative paths require the exact turn's working directory")
        let data = try record("turn_context", ["turn_id": "turn-a", "cwd": "/work"]) + record("response_item", call())
        XCTAssertNotNil(CodexFileApprovalPaths.records(data, discardingFirst: false, turn: "turn-a", item: "call-a"))
        XCTAssertNil(CodexFileApprovalPaths.records(data, discardingFirst: false, turn: "turn-b", item: "call-a"))
        XCTAssertNil(CodexFileApprovalPaths.records(data, discardingFirst: false, turn: "turn-a", item: "call-b"))
        XCTAssertNil(CodexFileApprovalPaths.records(data + data, discardingFirst: false, turn: "turn-a", item: "call-a"))
        XCTAssertNil(CodexFileApprovalPaths.records(Data(data.dropLast()), discardingFirst: false, turn: "turn-a", item: "call-a"))
        let output = try record("response_item", ["type": "custom_tool_call_output", "call_id": "call-a",
                                               "internal_chat_message_metadata_passthrough": ["turn_id": "turn-a"]])
        XCTAssertNil(CodexFileApprovalPaths.records(data + output, discardingFirst: false, turn: "turn-a", item: "call-a"))
    }

    func testUnscopedTailNeedsNewTurnContextAndCannotBorrowOldTurn() throws {
        var unscoped = call(); unscoped.removeValue(forKey: "internal_chat_message_metadata_passthrough")
        let data = try record("response_item", unscoped)
        XCTAssertNil(CodexFileApprovalPaths.records(data, discardingFirst: false, turn: "turn-a", item: "call-a"))
        let context = try record("turn_context", ["turn_id": "turn-a", "cwd": "/work"])
        XCTAssertNotNil(CodexFileApprovalPaths.records(context + data, discardingFirst: false, turn: "turn-a", item: "call-a"))
        let other = try record("turn_context", ["turn_id": "other-turn"])
        XCTAssertNil(CodexFileApprovalPaths.records(context + other + data, discardingFirst: false, turn: "turn-a", item: "call-a"))
        let ended = try record("event_msg", ["type": "task_complete", "turn_id": "turn-a"])
        XCTAssertNil(CodexFileApprovalPaths.records(context + data + ended, discardingFirst: false, turn: "turn-a", item: "call-a"))
    }

    func testExactOwnedFileRejectsWrongHeaderOutsideRootAndOversizedCall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("fixture.jsonl")
        let header = try record("session_meta", ["id": thread])
        let context = try record("turn_context", ["turn_id": "turn-a", "cwd": "/actual-turn-directory"])
        try (header + context + record("response_item", call())).write(to: file)
        XCTAssertEqual(CodexFileApprovalPaths.pending(file: file, root: root, thread: thread, turn: "turn-a", item: "call-a")?.count, 4)
        XCTAssertEqual(CodexFileApprovalPaths.pending(file: file, root: root, thread: thread, turn: "turn-a", item: "call-a")?.first, "/actual-turn-directory/new.txt")
        XCTAssertNil(CodexFileApprovalPaths.pending(file: file, root: root, thread: UUID().uuidString, turn: "turn-a", item: "call-a"))
        let outside = root.appendingPathComponent("outside.jsonl")
        try Data(contentsOf: file).write(to: outside)
        XCTAssertNil(CodexFileApprovalPaths.pending(file: outside, root: root, thread: thread, turn: "turn-a", item: "call-a"))
        var oversized = call(); oversized["input"] = String(repeating: "+", count: 300 * 1024)
        try (header + context + record("response_item", oversized)).write(to: file)
        XCTAssertNil(CodexFileApprovalPaths.pending(file: file, root: root, thread: thread, turn: "turn-a", item: "call-a"))
    }
}
