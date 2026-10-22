import AppKit
import SwiftUI
import XCTest
@testable import NotchX

@MainActor
final class ReorderContextCapture {
    var context: ReorderableDragContext?
    var revision = 0
}

struct ReorderContextProbe: NSViewRepresentable {
    @Environment(\.reorderableDragContext) private var dragContext
    let capture: ReorderContextCapture
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { capture.context = dragContext; capture.revision += 1 }
}

@MainActor
enum NativeUI {
    private struct WaitFailure: Error {}

    static func waitFor(_ description: String, in view: NSView? = nil, timeout: Duration = .seconds(3),
                        file: StaticString = #filePath, line: UInt = #line,
                        until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            view?.layoutSubtreeIfNeeded()
            view?.displayIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        } while clock.now < deadline
        XCTFail("Timed out waiting for \(description)", file: file, line: line)
        throw WaitFailure()
    }

    static func waitForElement(in view: NSView, id: String, file: StaticString = #filePath, line: UInt = #line) async throws -> AnyObject {
        try await waitFor(id, in: view, file: file, line: line) {
            guard let frame = find(in: view, id: id)?.accessibilityFrame?() else { return false }
            return frame.width > 0 && frame.height > 0
        }
        return try XCTUnwrap(find(in: view, id: id), file: file, line: line)
    }

    static func window(containing id: String) async throws -> NSWindow {
        var result: NSWindow?
        try await waitFor("native window containing \(id)") {
            result = NSApp.windows.first { $0.isVisible && $0.contentView.map { find(in: $0, id: id) != nil } == true }
            return result != nil
        }
        return try XCTUnwrap(result)
    }

    // Zero-delay host work is enqueued before this barrier. Negative assertions
    // can inspect its result without sleeping for an arbitrary UI duration.
    static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func click(at screenPoint: NSPoint, in window: NSWindow) throws {
        let location = window.convertPoint(fromScreen: screenPoint)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            NSApp.sendEvent(event)
        }
    }

    static func find(in root: Any, id: String) -> AnyObject? { elements(in: root).first { $0.accessibilityIdentifier?() == id } }
    static func elements(in root: Any) -> [AnyObject] {
        let object = root as AnyObject
        return [object] + (object.accessibilityChildren?() ?? []).flatMap { elements(in: $0) }
    }
    static func nativeViews(in root: NSView) -> [NSView] { [root] + root.subviews.flatMap { nativeViews(in: $0) } }

    static func frame(in root: Any, id: String, context: String = "", file: StaticString = #filePath, line: UInt = #line) throws -> NSRect {
        let element = try XCTUnwrap(find(in: root, id: id), id + " " + context, file: file, line: line)
        return try XCTUnwrap(element.accessibilityFrame?(), id, file: file, line: line)
    }
}
