import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Marks our outgoing representations without loading or changing their content.
/// Import rejects these; AirDrop and external receivers still use the file/text.
enum ShelfDragOrigin {
    static let typeIdentifier = "app.notchx.shelf-drag"
    static let pasteboardType = NSPasteboard.PasteboardType(typeIdentifier)

    static func mark(_ provider: NSItemProvider) -> NSItemProvider {
        provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
            completion(Data([1]), nil)
            return nil
        }
        return provider
    }
}

/// Finder-compatible multi-item drags. Each managed/reference file is copied
/// to the receiver's destination; a receiver can never move the source away.
final class ShelfPromisedFile: NSFilePromiseProvider {
    let writer: ShelfPromiseWriter

    init(source: URL, name: String, type: String) {
        writer = ShelfPromiseWriter(source: source, name: name)
        super.init()
        fileType = type
        delegate = writer
    }

    required init?(coder: NSCoder) { nil }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        super.writableTypes(for: pasteboard) + [ShelfDragOrigin.pasteboardType]
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        type == ShelfDragOrigin.pasteboardType ? "1" : super.pasteboardPropertyList(forType: type)
    }
}

// All instance state is immutable; AppKit dispatches writes on the queue below.
final class ShelfPromiseWriter: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    let source: URL
    let name: String
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    init(source: URL, name: String) { self.source = source; self.name = name }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { name }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { Self.queue }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        write(to: url, completionHandler: completionHandler)
    }

    func write(to url: URL, completionHandler: @escaping (Error?) -> Void) {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
}

struct ShelfBatchDragSource: NSViewRepresentable {
    let items: [ShelfItem]
    let select: (NSEvent.ModifierFlags) -> Void
    let open: () -> Void

    func makeNSView(context: Context) -> ShelfBatchDragView { ShelfBatchDragView() }
    func updateNSView(_ view: ShelfBatchDragView, context: Context) { view.items = items; view.select = select; view.open = open }
}

final class ShelfBatchDragView: NSView, NSDraggingSource {
    var items: [ShelfItem] = []
    var select: ((NSEvent.ModifierFlags) -> Void)?
    var open: (() -> Void)?
    private var mouseDownEvent: NSEvent?
    private var didDrag = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        // Leave the item's remove button and SwiftUI context menu interactive.
        if local.y > bounds.maxY - 20, (bounds.midX + 4...bounds.midX + 31).contains(local.x) { return nil }
        if NSApp.currentEvent?.type == .rightMouseDown { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event; didDrag = false }
    override func mouseUp(with event: NSEvent) {
        if !didDrag {
            if event.clickCount == 2 { open?() } else { select?(event.modifierFlags) }
        }
        mouseDownEvent = nil
    }
    override func mouseDragged(with event: NSEvent) {
        guard let mouseDownEvent, !didDrag, items.count > 1,
              hypot(event.locationInWindow.x - mouseDownEvent.locationInWindow.x,
                    event.locationInWindow.y - mouseDownEvent.locationInWindow.y) >= 4 else { return }
        let writers = Self.pasteboardWriters(for: items)
        guard !writers.isEmpty else { return }
        didDrag = true
        let point = convert(event.locationInWindow, from: nil)
        let icon = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil) ?? NSImage()
        let draggingItems = writers.enumerated().map { index, writer in
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(NSRect(x: point.x + CGFloat(index * 3), y: point.y, width: 32, height: 32), contents: icon)
            return item
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    static func pasteboardWriters(for items: [ShelfItem]) -> [NSPasteboardWriting] {
        items.compactMap { item in
            if item.isFileBacked, let source = item.resolvedFileURL {
                let type = item.kind == .folder ? UTType.folder : (UTType(filenameExtension: source.pathExtension) ?? .data)
                return ShelfPromisedFile(source: source, name: source.lastPathComponent, type: type.identifier)
            }
            let writer = NSPasteboardItem()
            if let url = item.resolvedURL {
                writer.setString(url.absoluteString, forType: .URL)
                writer.setString(url.absoluteString, forType: .string)
            }
            else if let text = item.textValue { writer.setString(text, forType: .string) }
            else { return nil }
            writer.setString("1", forType: ShelfDragOrigin.pasteboardType)
            return writer
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
}
