import AppKit
import UniformTypeIdentifiers

/// Drag-approach policy. The host owns event listeners and the sampling timer;
/// this consumer inspects pasteboard metadata only, never payloads.
@MainActor
final class ShelfDragApproachMonitor {
    private let appState: AppState
    private let pasteboard: NSPasteboard
    private let pointerLocation: () -> NSPoint
    private let leftButtonDown: () -> Bool
    private let targetFrames: (_ keepingPresentation: Bool) -> [NSRect]
    private let owner = UUID()
    private var initialChangeCount: Int
    private var isTargeted = false
    private var isStarted = false

    init(appState: AppState, pasteboard: NSPasteboard = NSPasteboard(name: .drag),
         pointerLocation: @escaping () -> NSPoint = { NSEvent.mouseLocation },
         leftButtonDown: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 },
         targetFrames: @escaping (Bool) -> [NSRect]) {
        self.appState = appState
        self.pasteboard = pasteboard
        self.pointerLocation = pointerLocation
        self.leftButtonDown = leftButtonDown
        self.targetFrames = targetFrames
        initialChangeCount = pasteboard.changeCount
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        initialChangeCount = pasteboard.changeCount
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        finishDrag()
    }

    func handleMouseEvent(_ type: NSEvent.EventType, snapshot: IslandPointerSnapshot? = nil) {
        guard isStarted else { return }
        switch type {
        case .leftMouseDown, .leftMouseUp: finishDrag()
        case .leftMouseDragged: poll(snapshot: snapshot)
        default: break
        }
    }

    /// Shared compensation samples also recover an omitted native mouse-up.
    func poll(snapshot: IslandPointerSnapshot? = nil) {
        guard isStarted else { return }
        let sample = snapshot ?? IslandPointerSnapshot(location: pointerLocation(), pressedButtons: leftButtonDown() ? 1 : 0)
        guard appState.allowsShelfDragApproach, sample.leftButtonDown,
              pasteboard.changeCount != initialChangeCount, hasExternalContent else {
            finishDrag()
            return
        }
        let nearIsland = targetFrames(isTargeted).contains { $0.contains(sample.location) }
        guard nearIsland != isTargeted else { return }
        isTargeted = nearIsland
        if nearIsland { appState.beginShelfDragPresentation(owner: owner) }
        else { appState.endShelfDragPresentation(owner: owner) }
    }

    private var hasExternalContent: Bool {
        let types = pasteboard.types ?? []
        guard !types.contains(ShelfDragOrigin.pasteboardType) else { return false }
        // Inspect metadata only; never materialize promised files or read payloads.
        return types.contains { rawType in
            guard let type = UTType(rawType.rawValue) else { return false }
            return ShelfStore.acceptedDropTypes.contains { type.conforms(to: $0) }
        }
    }

    private func finishDrag() {
        initialChangeCount = pasteboard.changeCount
        if isTargeted {
            isTargeted = false
            appState.endShelfDragPresentation(owner: owner)
        }
    }

    deinit {
        let state = appState
        let dragOwner = owner
        Task { @MainActor in state.endShelfDragPresentation(owner: dragOwner) }
    }
}
