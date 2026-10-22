import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import NotchX

@MainActor
final class ReorderableContainerTests: XCTestCase {
    func testUpstreamEdgesAndDestinationsMatchIndependentInsertions() {
        XCTAssertEqual(dropEdge(at: CGPoint(x: 0, y: 19), in: CGSize(width: 100, height: 40)), .before)
        XCTAssertEqual(dropEdge(at: CGPoint(x: 0, y: 20), in: CGSize(width: 100, height: 40)), .after)
        let original = Array(0..<11)
        for source in original {
            for target in original {
                for edge in [ReorderableDropEdge.before, .after] {
                    let destination = reorderDestination(currentIndex: source, targetIndex: target, edge: edge)
                    let crossesTarget = source < target && edge == .after || source > target && edge == .before
                    guard crossesTarget else { XCTAssertNil(destination); continue }
                    guard let destination else { XCTFail("Missing crossed-target move"); continue }
                    var actual = original
                    actual.move(fromOffsets: IndexSet(integer: source), toOffset: destination)
                    var expected = original.filter { $0 != source }
                    let position = expected.firstIndex(of: target)! + (edge == .after ? 1 : 0)
                    expected.insert(source, at: position)
                    XCTAssertEqual(actual, expected, "source=\(source), target=\(target), edge=\(edge)")
                }
            }
        }
    }

    func testUpstreamContainerHandlersMoveReverseAndClearWithoutRollback() async throws {
        let model = ReorderModel()
        let capture = ReorderContextCapture()
        let host = NSHostingView(rootView: ReorderHarness(model: model, capture: capture))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        try await NativeUI.waitFor("upstream reorder context", in: host) { capture.context != nil }
        let first = model.items[0]
        var revision = capture.revision
        try XCTUnwrap(capture.context).startDrag(first)
        try await NativeUI.waitFor("upstream drag start", in: host) { capture.revision > revision && model.dragged == [first] }
        XCTAssertTrue(try XCTUnwrap(capture.context).isDragged(first))
        revision = capture.revision
        try XCTUnwrap(capture.context).move(ReorderToken(id: 2), .after)
        try await NativeUI.waitFor("forward hover move", in: host) { capture.revision > revision }
        XCTAssertEqual(model.items.map(\.id), [1, 2, 0, 3])
        revision = capture.revision
        try XCTUnwrap(capture.context).move(ReorderToken(id: 1), .before)
        try await NativeUI.waitFor("reverse hover move", in: host) { capture.revision > revision }
        XCTAssertEqual(model.items.map(\.id), [0, 1, 2, 3])
        try XCTUnwrap(capture.context).move(ReorderToken(id: 1), .before)
        try XCTUnwrap(capture.context).move(first, .after)
        try XCTUnwrap(capture.context).move("foreign item", .after)
        XCTAssertEqual(model.items.map(\.id), [0, 1, 2, 3])
        try XCTUnwrap(capture.context).resetDragState()
        try await NativeUI.waitFor("session cleanup", in: host) { model.dragged.isEmpty }
        XCTAssertFalse(try XCTUnwrap(capture.context).isDragged(first))

        revision = capture.revision
        try XCTUnwrap(capture.context).startDrag(ReorderToken(id: 3))
        try await NativeUI.waitFor("next drag", in: host) { capture.revision > revision && model.dragged.map(\.id) == [3] }
        revision = capture.revision
        try XCTUnwrap(capture.context).move(ReorderToken(id: 1), .before)
        try await NativeUI.waitFor("next hover", in: host) { capture.revision > revision }
        XCTAssertEqual(model.items.map(\.id), [0, 3, 1, 2])
        try XCTUnwrap(capture.context).resetDragState()
        try await NativeUI.waitFor("cancel cleanup without rollback", in: host) { model.dragged.isEmpty }
        XCTAssertEqual(model.items.map(\.id), [0, 3, 1, 2])
    }
}

private struct ReorderToken: Identifiable, Equatable { let id: Int }

@MainActor
private final class ReorderModel: ObservableObject {
    @Published var items = (0..<4).map { ReorderToken(id: $0) }
    @Published var dragged: [ReorderToken] = []
}

private struct ReorderHarness: View {
    @ObservedObject var model: ReorderModel
    let capture: ReorderContextCapture
    var body: some View {
        ReorderContextProbe(capture: capture)
            .draggableContainer(items: model.items, contentType: .data,
                dragPreview: { items in Text(verbatim: items.map { String($0.id) }.joined()) },
                draggedItems: $model.dragged, moveAction: { model.items.move(fromOffsets: $0, toOffset: $1) })
    }
}
