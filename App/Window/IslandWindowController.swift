import AppKit
import SwiftUI
import Combine

private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Container that keeps the hosting view centered horizontally and
/// pinned to the top, regardless of the container/window size.
/// Unlike autoresizingMask, this handles the 0-margin edge case correctly.
private final class CenteringContainerView: NSView {
    override func layout() {
        super.layout()
        guard let hostingView = subviews.first else { return }
        // Avoid invalidating a hosting view again during an unchanged layout pass.
        // AppKit coords: y=0 at bottom. Pin hosting view top to container top.
        let origin = NSPoint(
            x: (bounds.width - hostingView.frame.width) / 2,
            y: bounds.height - hostingView.frame.height
        )
        if hostingView.frame.origin != origin {
            hostingView.setFrameOrigin(origin)
        }
    }
}

@MainActor
final class IslandWindowController {
    /// Panels keyed by the display id string they live on.
    private var panels: [String: IslandPanel] = [:]
    /// Screens currently hidden because a fullscreen app is covering them.
    private var hiddenForFullscreen: Set<String> = []
    private let appState: AppState
    private let shelf: ShelfStore?
    private var screenObserver: Any?
    private var defaultsObserver: Any?
    private var activeSpaceObserver: Any?
    private var fullscreenPollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var settledWindowSize: CGSize?
    private var isShowing = false
    private var shelfDragMonitor: ShelfDragApproachMonitor?
    private let pointerSource: () -> IslandPointerSnapshot
    private let panelIsOnActiveSpace: @MainActor (NSWindow) -> Bool
    private var lastPointerSample: IslandPointerSnapshot?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var pointerTimer: Timer?
    private var pendingPointerSample: DispatchWorkItem?
    private var settledHoverFrames: [String: NSRect] = [:]
    private var motionHoverFrames: [String: NSRect] = [:]

    convenience init() {
        self.init(appState: .shared)
    }

    init(appState: AppState, shelf: ShelfStore? = nil,
         pointerSource: @escaping () -> IslandPointerSnapshot = { .live },
         panelIsOnActiveSpace: @escaping @MainActor (NSWindow) -> Bool = { $0.isOnActiveSpace }) {
        self.appState = appState
        self.shelf = shelf
        self.pointerSource = pointerSource
        self.panelIsOnActiveSpace = panelIsOnActiveSpace
    }

    /// The actual AppKit windows, also used to verify viewport behavior.
    var windows: [NSWindow] { Array(panels.values) }

    func showIsland() {
        guard !isShowing else { return }
        isShowing = true
        setupDidChangeStateHook()
        syncPanels(display: true)
        settledWindowSize = appState.windowSize

        observeScreenChanges()
        observeSettingsChanges()
        observeCompactLayoutChanges()
        observeFullscreenChanges()
        updateFullscreenVisibility()
    }

    func hideIsland() {
        isShowing = false
        shelfDragMonitor?.stop()
        appState.cancelShelfDragPresentation()
        for panel in panels.values {
            panel.orderOut(nil)
        }
        stopPointerMonitoring()
        stopObserving()
        appState.suppressDismissScheduling = false
        motionHoverFrames.removeAll()
    }

    // MARK: - Panel lifecycle

    /// Reconciles the set of panels with the set of target screens.
    /// Creates new panels for screens that don't have one yet and tears
    /// down panels for screens that are no longer in the target set.
    private func syncPanels(display: Bool) {
        guard isShowing else { return }

        let targets = targetScreens()
        let targetIDs = Set(targets.compactMap { ScreenDetector.displayIDString(for: $0) })

        // Remove panels for screens that are no longer targeted (or disconnected).
        for (id, panel) in panels where !targetIDs.contains(id) {
            panel.orderOut(nil)
            panels.removeValue(forKey: id)
            hiddenForFullscreen.remove(id)
            settledHoverFrames.removeValue(forKey: id)
            motionHoverFrames.removeValue(forKey: id)
        }

        // Pick the screen that drives the shared SwiftUI presentation context.
        // Preference order: user-picked single display → primary screen if targeted
        // → first notched target → first target.
        let primary = preferredPresentationScreen(from: targets)
        if let primary {
            appState.updatePresentationContext(screen: primary)
        }

        // Create or update a panel for each target screen.
        for screen in targets {
            guard let id = ScreenDetector.displayIDString(for: screen) else { continue }
            let panel = panels[id] ?? makePanel()
            if panels[id] == nil {
                panels[id] = panel
            }
            let target = needsReservedViewport ? maxWindowSize : appState.windowSize
            applyFrame(size: needsReservedViewport ? reservedSize(current: panel.frame.size, target: target) : target, to: panel, screen: screen, display: display)
            panel.setVisibleInScreenRecordings(appState.showInScreenRecordings)
            panel.setVisibleOnAllSpaces(appState.showOnAllSpaces)
            if !hiddenForFullscreen.contains(id) {
                panel.orderFrontRegardless()
            }
            if !needsReservedViewport { settledHoverFrames[id] = logicalHoverFrame(for: panel) }
        }
        updateShelfDragMonitoring()
        updatePointerMonitoring()
    }

    // MARK: - Central pointer input

    private func logicalHoverFrame(for panel: IslandPanel) -> NSRect {
        let size = appState.windowSize
        return NSRect(x: panel.frame.midX - size.width / 2, y: panel.frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    func pointerRegions() -> [IslandPointerRegion] {
        guard isShowing else { return [] }
        return panels.compactMap { id, panel in
            guard panel.isVisible, panelIsOnActiveSpace(panel), !hiddenForFullscreen.contains(id),
                  let screen = ScreenDetector.screen(withIDString: id) else { return nil }
            return IslandPointerRegion(frame: motionHoverFrames[id] ?? logicalHoverFrame(for: panel), screenFrame: screen.frame)
        }
    }

    private func updatePointerMonitoring() {
        guard !pointerRegions().isEmpty else { stopPointerMonitoring(); return }
        appState.pointerSamplingRequested = { [weak self] in self?.requestPointerSample() }
        appState.pointerMovementResetRequested = { [weak self] in
            guard let self else { return }
            // Movement before the outgoing click must not rearm the resulting
            // collapse when that event's deferred sample is finally delivered.
            self.lastPointerSample = self.pointerSource()
        }
        if localPointerMonitor == nil {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
                .rightMouseDown, .rightMouseUp, .rightMouseDragged, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
            globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                MainActor.assumeIsolated { self?.receivePointerEvent(event.type) }
            }
            localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                self?.receivePointerEvent(event.type)
                return event
            }
        }
        // Sample outside AppKit/SwiftUI layout and native event dispatch.
        requestPointerSample()
    }

    private func receivePointerEvent(_ type: NSEvent.EventType) {
        // Preserve drag boundaries even when multiple moves are coalesced.
        if type == .leftMouseDown || type == .leftMouseUp { shelfDragMonitor?.handleMouseEvent(type) }
        requestPointerSample()
    }

    private func requestPointerSample() {
        guard isShowing, pendingPointerSample == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPointerSample = nil
            self.samplePointer()
        }
        pendingPointerSample = work
        DispatchQueue.main.async(execute: work)
    }

    /// Also callable after geometry/visibility changes and by deterministic
    /// input-boundary tests; physical input is read exactly once per sample.
    func samplePointer() {
        let regions = pointerRegions()
        guard !regions.isEmpty else { stopPointerMonitoring(); return }
        let sample = pointerSource()
        let moved = lastPointerSample.map { $0.location != sample.location } ?? false
        lastPointerSample = sample
        appState.setPointerInputAvailable(true)
        shelfDragMonitor?.poll(snapshot: sample)
        let hovering = IslandPointerRegion.isHovering(at: sample.location, regions: regions, keepingHover: appState.isHovering)
        appState.handlePointerSample(hovering: hovering, moved: moved, leftButtonDown: sample.leftButtonDown)
        let interval = sample.pressedButtons != 0 || appState.isSurfaceMotionActive ? 0.05 : (hovering ? 0.25 : 0.5)
        if pointerTimer?.timeInterval != interval {
            pointerTimer?.invalidate()
            let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.samplePointer() }
            }
            timer.tolerance = interval * 0.2
            pointerTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopPointerMonitoring() {
        pendingPointerSample?.cancel()
        pendingPointerSample = nil
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        localPointerMonitor = nil
        globalPointerMonitor = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        lastPointerSample = nil
        shelfDragMonitor?.stop()
        appState.cancelShelfDragPresentation()
        appState.pointerSamplingRequested = nil
        appState.pointerMovementResetRequested = nil
        appState.setPointerInputAvailable(false)
    }

    private func updateShelfDragMonitoring() {
        guard isShowing, appState.shelfEnabled, appState.shelfExpandOnDragApproach else {
            shelfDragMonitor?.stop()
            return
        }
        if shelfDragMonitor == nil {
            shelfDragMonitor = ShelfDragApproachMonitor(appState: appState) { [weak self] keepingPresentation in
                self?.shelfDragApproachFrames(keepingPresentation: keepingPresentation) ?? []
            }
        }
        shelfDragMonitor?.start()
    }

    func shelfDragApproachFrames(keepingPresentation: Bool) -> [NSRect] {
        guard isShowing else { return [] }
        return panels.compactMap { id, panel in
            guard panel.isVisible, panelIsOnActiveSpace(panel), !hiddenForFullscreen.contains(id),
                  let screen = ScreenDetector.screen(withIDString: id) else { return nil }
            let compact = appState.windowSize(for: .compact)
            // A narrow band below the compact island; no screen-wide hot zone.
            var region = NSRect(x: panel.frame.midX - compact.width / 2 - 40,
                                y: panel.frame.maxY - compact.height - 80,
                                width: compact.width + 80, height: compact.height + 80)
            if keepingPresentation {
                let size = appState.currentSize
                region = region.union(NSRect(x: panel.frame.midX - size.width / 2,
                                             y: panel.frame.maxY - size.height, width: size.width, height: size.height))
            }
            return region.intersection(screen.frame)
        }
    }

    private func makePanel() -> IslandPanel {
        let panel = IslandPanel()

        // Keep a stable hosting capacity while the window clips the surface:
        // compact window → only the notch area is visible/clickable,
        // expanded window → the full surface is revealed.
        // grow it for larger modules, but never shrink it during a reversal.
        let maxSize = maxWindowSize
        let hostingView = FirstMouseHostingView(
            rootView: IslandContainerView(shelf: shelf)
                .environmentObject(appState)
                .notchXLocalized()
        )
        // AppKit owns this frame. Intrinsic/minimum sizing must not move the
        // panel or center a larger SwiftUI surface above its viewport.
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(x: 0, y: 0, width: maxSize.width, height: maxSize.height)
        hostingView.autoresizingMask = [] // Capacity and top anchoring are managed below.

        let containerView = CenteringContainerView()
        containerView.addSubview(hostingView)
        panel.contentView = containerView

        return panel
    }

    /// The set of screens the island should currently be visible on,
    /// derived from the user's display setting.
    private func targetScreens() -> [NSScreen] {
        let id = appState.displayIdentifier

        if id == ScreenDetector.allDisplaysIdentifier {
            return NSScreen.screens
        }

        if !id.isEmpty, let chosen = ScreenDetector.screen(withIDString: id) {
            return [chosen]
        }

        // Automatic: cursor screen → primary → first connected.
        let fallback = ScreenDetector.activeScreen
            ?? ScreenDetector.primaryScreen
            ?? NSScreen.screens.first
        return fallback.map { [$0] } ?? []
    }

    private func preferredPresentationScreen(from targets: [NSScreen]) -> NSScreen? {
        if targets.count == 1 { return targets.first }
        // Prefer a notched screen when one is in the target set. The notched
        // shape is the more constrained of the two — rendering as "notched"
        // on a non-notched display shows a pill at the top, which is tolerable;
        // rendering as "non-notched" on a notched display leaves the pill
        // floating away from the camera housing, which is visually broken.
        if let notched = targets.first(where: { ScreenDetector.hasNotch(screen: $0) }) {
            return notched
        }
        if let main = ScreenDetector.primaryScreen,
           targets.contains(where: { $0 == main }) {
            return main
        }
        return targets.first
    }

    // MARK: - Positioning

    private var maxWindowSize: CGSize {
        let full = appState.windowSize(for: .fullExpanded)
        let expanded = appState.windowSize(for: .expanded)
        return CGSize(
            width: max(full.width, expanded.width),
            height: max(full.height, expanded.height)
        )
    }

    private func applyFrame(size: CGSize, to panel: IslandPanel, screen: NSScreen, display: Bool = true) {
        if let container = panel.contentView, let hosting = container.subviews.first {
            let maximum = maxWindowSize
            let capacity = CGSize(width: max(hosting.frame.width, maximum.width),
                                  height: max(hosting.frame.height, maximum.height))
            if hosting.frame.size != capacity { hosting.setFrameSize(capacity) }
        }
        let screenFrame = screen.frame
        let hasNotch = ScreenDetector.hasNotch(screen: screen)
        let notchRect = ScreenDetector.notchRect(screen: screen)

        let anchorX: CGFloat
        let anchorY: CGFloat
        if hasNotch, let notch = notchRect {
            anchorX = notch.midX
            anchorY = notch.maxY - Constants.expandedTopInset
        } else {
            anchorX = screenFrame.midX
            anchorY = screenFrame.maxY - Constants.expandedTopInset
        }

        let x = anchorX - size.width / 2
        let y = anchorY - size.height
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: display)
        }
        // Growing the hosting capacity also needs repositioning when the
        // native viewport itself has not changed. Keep both top edges aligned.
        panel.contentView?.needsLayout = true
        panel.contentView?.layoutSubtreeIfNeeded()
    }

    /// Apply the given size to every active panel, each sized against its own screen.
    private func applyFrameToAll(size: CGSize, display: Bool = true) {
        for (id, panel) in panels {
            guard let screen = ScreenDetector.screen(withIDString: id) else { continue }
            applyFrame(size: needsReservedViewport ? reservedSize(current: panel.frame.size, target: size) : size, to: panel, screen: screen, display: display)
        }
    }

    private var needsReservedViewport: Bool { appState.isSurfaceMotionActive || appState.suppressDismissScheduling }

    // MARK: - Window resize via didSet hook
    //
    // Fires from AppState.didSet — AFTER currentState has changed,
    // still INSIDE the withAnimation() block. No GeometryReader exists,
    // so the resize is invisible to SwiftUI. The surface stays centered
    // on the notch because both the window and surface are notch-centered.

    private func setupDidChangeStateHook() {
        // Reserve the viewport synchronously, before SwiftUI starts drawing an
        // expanded surface. A reversal must never crop the animation in flight.
        appState.didChangeState = { [weak self] _, _ in self?.prepareSurfaceMotion() }
        appState.surfaceMotionBegan = { [weak self] in self?.prepareSurfaceMotion() }
        appState.surfaceMotionSettled = { [weak self] in self?.finishSurfaceMotion() }
    }

    private func prepareSurfaceMotion() {
        guard isShowing else { return }
        appState.suppressDismissScheduling = true
        appState.cancelAutoDismiss()
        appState.cancelFullExpandedDismiss()
        // A new target can be smaller when a disclosure closes. Keep the actual
        // old viewport until the shell settles, not only the hosting capacity.
        for (id, panel) in panels {
            guard let screen = ScreenDetector.screen(withIDString: id) else { continue }
            let target = logicalHoverFrame(for: panel)
            motionHoverFrames[id] = (motionHoverFrames[id] ?? settledHoverFrames[id] ?? target).union(target)
            applyFrame(size: reservedSize(current: panel.frame.size, target: maxWindowSize), to: panel, screen: screen)
        }
    }

    private func reservedSize(current: CGSize, target: CGSize) -> CGSize {
        CGSize(width: max(current.width, target.width), height: max(current.height, target.height))
    }

    private func finishSurfaceMotion() {
        guard isShowing, !appState.isSurfaceMotionActive else { return }
        appState.suppressDismissScheduling = false
        let size = appState.windowSize
        applyFrameToAll(size: size)
        settledWindowSize = appState.windowSize
        motionHoverFrames.removeAll()
        for (id, panel) in panels { settledHoverFrames[id] = logicalHoverFrame(for: panel) }
        for panel in panels.values {
            panel.contentView?.subviews.forEach { $0.updateTrackingAreas() }
        }
        requestPointerSample()
    }

    // MARK: - Compact layout changes

    private func observeCompactLayoutChanges() {
        appState.$activeModule
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateCompactFrameIfNeeded()
            }
            .store(in: &cancellables)

        appState.$modulePresentationRevision
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateCompactFrameIfNeeded()
            }
            .store(in: &cancellables)
        appState.$isKeepAwakeActive
            .removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateCompactFrameIfNeeded() }
            .store(in: &cancellables)
        appState.$isKeyboardCleaningActive
            .removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateFullscreenVisibility() }
            .store(in: &cancellables)
    }

    private func updateCompactFrameIfNeeded() {
        guard appState.currentState == .compact else { return }
        guard appState.isSurfaceMotionActive || settledWindowSize != appState.windowSize else { return }
        // Media notifications can arrive during collapse. Only the surface's
        // completion callback is allowed to shrink this viewport.
        prepareSurfaceMotion()
    }

    // MARK: - Screen & Settings

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Screen topology may have changed (display added/removed) —
                // reconcile the panel set, then re-apply sizes.
                self.syncPanels(display: true)
                let size = self.appState.currentState == .compact && !self.appState.isSurfaceMotionActive
                    ? self.appState.windowSize : self.maxWindowSize
                self.applyFrameToAll(size: size)
                self.requestPointerSample()
            }
        }
    }

    private func observeSettingsChanges() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                for panel in self.panels.values {
                    panel.setVisibleInScreenRecordings(self.appState.showInScreenRecordings)
                }
                // The display identifier may have changed — reconcile the
                // panel set (handles switching to/from All Displays and
                // moving between single screens). Also keeps compact frame
                // in sync with size-affecting settings like "Hide side slots".
                self.syncPanels(display: true)
                self.updateCompactFrameIfNeeded()
                self.updateFullscreenVisibility()
            }
        }
    }

    // MARK: - Fullscreen hiding
    //
    // When the user opts in via Settings we hide each panel individually
    // while a non-NotchX window exactly covers its screen (the classic
    // signature of a native macOS fullscreen app). Each screen is evaluated
    // independently so an external monitor running fullscreen video doesn't
    // pull down the island on the MacBook's built-in display.

    private func observeFullscreenChanges() {
        // activeSpaceDidChange fires when the user enters/exits fullscreen
        // (each fullscreen app gets its own space) or switches spaces.
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFullscreenVisibility()
            }
        }

        // Low-frequency safety net: some fullscreen transitions (e.g. the
        // native video player going fullscreen in-place) don't always fire
        // a space change notification, so re-check every 2s while the
        // controller is alive. The check is cheap (CGWindowListCopyWindowInfo
        // with bounds only) and only runs as long as the app is up.
        fullscreenPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateFullscreenVisibility()
            }
        }
    }

    private func updateFullscreenVisibility() {
        guard isShowing else { return }
        let shouldConsider = appState.hideOnFullscreen && !appState.isKeyboardCleaningActive

        for (id, panel) in panels {
            guard let screen = ScreenDetector.screen(withIDString: id) else { continue }

            let wasHidden = hiddenForFullscreen.contains(id)
            let fullscreen = shouldConsider && Self.isFullscreenWindowPresent(on: screen)

            if fullscreen && !wasHidden {
                hiddenForFullscreen.insert(id)
                panel.orderOut(nil)
            } else if !fullscreen && wasHidden {
                hiddenForFullscreen.remove(id)
                panel.orderFrontRegardless()
            }
        }
        updatePointerMonitoring()
    }

    /// Returns true when any on-screen window from another process exactly
    /// covers the given screen's frame — the classic signature of a native
    /// macOS fullscreen app.
    private static func isFullscreenWindowPresent(on screen: NSScreen) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }

        let ourPID = Int(ProcessInfo.processInfo.processIdentifier)
        let screenFrame = screen.frame

        for window in info {
            // Skip windows owned by NotchX itself.
            if let pid = window[kCGWindowOwnerPID as String] as? Int, pid == ourPID {
                continue
            }
            // Only consider windows in the normal content layer. The menu
            // bar, Dock, and status items live on non-zero layers.
            if let layer = window[kCGWindowLayer as String] as? Int, layer != 0 {
                continue
            }
            guard let boundsDict = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else {
                continue
            }
            // CGWindow bounds use pixel sizes; compare width/height with a
            // small tolerance to guard against rounding on Retina screens.
            if abs(rect.width - screenFrame.width) < 1.5
                && abs(rect.height - screenFrame.height) < 1.5 {
                return true
            }
        }
        return false
    }

    private func stopObserving() {
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        screenObserver = nil
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        defaultsObserver = nil
        if let observer = activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        activeSpaceObserver = nil
        fullscreenPollTimer?.invalidate()
        fullscreenPollTimer = nil
        cancellables.removeAll()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if let activeSpaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        pendingPointerSample?.cancel()
        pointerTimer?.invalidate()
        fullscreenPollTimer?.invalidate()
    }
}
