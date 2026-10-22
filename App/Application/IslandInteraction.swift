import AppKit
import SwiftUI

struct IslandInteractionToken: Hashable {
    let id = UUID()
    let module: ModuleType?
}

enum IslandHandoffKind {
    case window
    case fileSelection
    case external
}

enum IslandHandoffOutcome {
    case completed
    case cancelled
    case failed
}

struct IslandPresentationHandoff: Equatable {
    let id = UUID()
    let kind: IslandHandoffKind
    let module: ModuleType?
    let returnTab: FullExpandedTab?
}

/// Native popovers keep their source surface stable and release their own hold
/// on every exit, including an outgoing page or a new window handoff.
private struct IslandPopoverInteraction: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @Environment(\.islandContentActive) private var contentActive
    @Binding var isPresented: Bool
    let module: ModuleType
    @State private var token: IslandInteractionToken?

    func body(content: Content) -> some View {
        content
            .onAppear { updateInteraction() }
            .onChange(of: isPresented) { _, _ in updateInteraction() }
            .onChange(of: contentActive) { _, active in if !active { close() } }
            .onChange(of: appState.presentationHandoffRevision) { _, _ in close() }
            .onChange(of: appState.isModuleEnabled(module)) { _, enabled in if !enabled { close() } }
            .onDisappear { close() }
    }

    private func updateInteraction() {
        if isPresented, contentActive, appState.isModuleEnabled(module) {
            if token == nil { token = appState.beginControlInteraction(for: module) }
        } else { release() }
    }

    private func close() { isPresented = false; release() }
    private func release() {
        guard let token else { return }
        self.token = nil
        appState.endControlInteraction(token)
    }
}

extension View {
    func islandPopoverInteraction(isPresented: Binding<Bool>, module: ModuleType) -> some View {
        modifier(IslandPopoverInteraction(isPresented: isPresented, module: module))
    }
}

/// A native text field does not normally resign when blank space is clicked.
/// This boundary releases only its own focus and leaves the event untouched.
struct IslandTextInputFocusBoundary: NSViewRepresentable {
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> IslandTextInputBoundaryView { IslandTextInputBoundaryView() }
    func updateNSView(_ view: IslandTextInputBoundaryView, context: Context) {
        view.isEditing = isFocused
        view.onBlur = { isFocused = false }
    }
    static func dismantleNSView(_ view: IslandTextInputBoundaryView, coordinator: ()) { view.stop() }
}

final class IslandTextInputBoundaryView: NSView {
    var isEditing = false
    var onBlur: (() -> Void)?
    private var mouseMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.blur(resignResponder: false) }
            }
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard isEditing, let window else { return }
        if event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) {
            blur(resignResponder: event.window === window)
        }
    }

    private func blur(resignResponder: Bool) {
        guard isEditing else { return }
        isEditing = false
        onBlur?()
        if resignResponder { window?.makeFirstResponder(nil) }
    }

    func stop() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        mouseMonitor = nil
        resignObserver = nil
    }

    deinit {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }
}

/// Window geometry stays in the AppKit layer; business and host state never
/// depend on a window controller's frame calculations.
@MainActor
struct IslandWindowContext {
    let screen: NSScreen
    let islandFrame: NSRect?

    init?(sourceWindow: NSWindow?, appState: AppState) {
        guard let screen = sourceWindow?.screen ?? ScreenDetector.activeScreen ?? NSScreen.main else { return nil }
        self.screen = screen
        let island = (sourceWindow as? IslandPanel) ?? NSApp.windows.compactMap { $0 as? IslandPanel }
            .first { $0.isVisible && $0.screen == screen }
        islandFrame = appState.lockFullExpandedInPlace && appState.currentState == .fullExpanded ? island?.frame : nil
    }
}

enum IslandWindowPlacement {
    @MainActor
    static func minimumFrameSize(for window: NSWindow, contentMinimum: NSSize = .zero) -> NSSize {
        let content = NSSize(width: max(contentMinimum.width, window.contentMinSize.width),
                             height: max(contentMinimum.height, window.contentMinSize.height))
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
        return NSSize(width: max(window.minSize.width, frame.width), height: max(window.minSize.height, frame.height))
    }

    static func frame(size: NSSize, savedFrame: NSRect?, visibleFrame: NSRect, islandFrame: NSRect?,
                      minimumSize: NSSize) -> NSRect {
        var available = visibleFrame
        if let islandFrame, islandFrame.intersects(visibleFrame) {
            let belowHeight = max(0, min(visibleFrame.maxY, islandFrame.minY - 12) - visibleFrame.minY)
            // Avoidance is optional when it would make native content unusable.
            if belowHeight >= minimumSize.height { available.size.height = belowHeight }
        }
        let saved = savedFrame.flatMap { frame -> NSRect? in
            guard frame.origin.x.isFinite, frame.origin.y.isFinite, frame.width.isFinite, frame.height.isFinite,
                  frame.width >= minimumSize.width, frame.height >= minimumSize.height, frame.intersects(visibleFrame) else { return nil }
            return frame
        }
        let desired = saved?.size ?? size
        let fitted = NSSize(width: max(minimumSize.width, min(desired.width, available.width)),
                            height: max(minimumSize.height, min(desired.height, available.height)))
        let origin = saved?.origin ?? NSPoint(x: available.midX - fitted.width / 2,
            y: available.midY + available.height * 0.08 - fitted.height / 2)
        return NSRect(x: min(max(origin.x, available.minX), available.maxX - fitted.width),
                      y: min(max(origin.y, available.minY), available.maxY - fitted.height),
                      width: fitted.width, height: fitted.height)
    }
}
