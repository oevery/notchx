import SwiftUI

struct IslandContainerView: View {
    private let shelf: ShelfStore?
    @EnvironmentObject var appState: AppState
    @Namespace private var artworkNamespace
    @State private var motionOwner = UUID()
    @State private var renderedSurface: SurfaceGeometry?
    @State private var isShelfDropTargeted = false
    @State private var shelfDragEndWorkItem: DispatchWorkItem?

    init(shelf: ShelfStore? = nil) { self.shelf = shelf }

    var body: some View {
        // No GeometryReader — just like NotchDrop. The surface sizes
        // itself from appState. Transparent areas around the surface
        // are truly empty (alpha=0), so macOS passes clicks through.
        ZStack(alignment: .top) {
            islandSurface
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The island surface stays black in either system appearance. Resolve
        // semantic text and native controls against that local dark surface.
        // Also set the presentation preference: an environment override alone
        // leaves AppKit popovers/dialogs in the system's light appearance.
        .environment(\.colorScheme, .dark)
        .preferredColorScheme(.dark)
        .notchXLocalized()
        .environment(\.playbackArtworkNamespace, artworkNamespace)
        .environment(\.playbackArtworkTrackID, appState.nowPlayingEnabled ? NowPlayingManager.shared.presentationTrackID : "")
        .environment(\.islandMotion, appState.motion)
        .environment(\.islandContentSelection, IslandContentSelection(
            state: appState.currentState, module: appState.currentState == .compact ? appState.compactPresentationModule : appState.activeModule,
            tab: appState.fullExpandedSelectedTab))
        .onAppear {
            renderedSurface = targetSurface
            Task { @MainActor in appState.settleInitialSurface() }
        }
        .onChange(of: targetSurface) { _, target in transitionSurface(to: target) }
        .onDisappear {
            renderedSurface = nil
            shelfDragEndWorkItem?.cancel()
            shelfDragEndWorkItem = nil
            appState.endShelfDragPresentation(owner: motionOwner)
            appState.removeSurfaceMotion(owner: motionOwner)
        }
        .onChange(of: isShelfDropTargeted) { _, isTargeted in
            handleShelfDropTargetChange(isTargeted)
        }
        .onChange(of: appState.isShelfDragActive) { _, active in
            if !active {
                shelfDragEndWorkItem?.cancel()
                shelfDragEndWorkItem = nil
                isShelfDropTargeted = false
            }
        }
    }

    // MARK: - Surface

    private var islandSurface: some View {
        let surfaceSize = (renderedSurface ?? targetSurface).size
        return ZStack(alignment: .top) {
            islandShape
                .fill(
                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.98),
                            Color.black.opacity(0.94)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            islandContent
                .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height)
        .clipShape(islandShape)
        .compositingGroup()
        .shadow(
            color: .black.opacity(ambientShadowOpacity),
            radius: ambientShadowRadius,
            y: ambientShadowYOffset
        )
        .shadow(
            color: .black.opacity(keyShadowOpacity),
            radius: keyShadowRadius,
            y: keyShadowYOffset
        )
        .overlay {
            if appState.shelfEnabled && isShelfDropTargeted {
                islandShape
                    .stroke(Color.accentColor.opacity(0.92), style: StrokeStyle(lineWidth: 3, dash: [10]))
                    .padding(1)
            }
        }
        .contentShape(IslandInteractionShape(surface: islandShape, horizontalInset: compactInteractionInset))
        .modifier(IslandSurfaceSwipeModifier(
            enabled: appState.islandSurfaceSwipeEnabled,
            suppressGesture: !appState.canHandleIslandSurfaceGesture,
            isCompact: appState.currentState == .compact,
            onTrackpad: { handleHorizontalSwipe($0) },
            onDragEnded: { handleSwipe(value: $0) }
        ))
        .onTapGesture {
            handleSurfaceTap()
        }
        .gesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    guard appState.canHandleIslandSurfaceGesture else { return }
                    AppDelegate.showSettingsWindow(fromIsland: appState)
                }
        )
        .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $isShelfDropTargeted) { providers in
            guard appState.shelfEnabled else { return false }
            return (shelf ?? .shared).handleDrop(providers: providers) { _ in
                appState.presentShelfAfterDrop()
            }
        }
    }

    // MARK: - Content

    private var compactInteractionInset: CGFloat {
        appState.currentState == .compact ? appState.compactSideCornerInset : 0
    }

    private var islandContent: some View {
        let compact = appState.currentState == .compact
        let showCompact = compact
        let compactSize = appState.size(for: .compact)
        return ZStack(alignment: .top) {
            // Keep the final compact geometry anchored at the top. The shell
            // and content crossfade together; corner space belongs to the host.
            CompactView(module: appState.compactPresentationModule, minimal: appState.shouldUseMinimalCompactLayout)
                .environment(\.islandContentActive, showCompact)
                .frame(width: compactSize.width, height: compactSize.height)
                .opacity(showCompact ? 1 : 0)
                .accessibilityElement(children: .contain)
                .allowsHitTesting(showCompact)
                .disabled(!showCompact)
                .accessibilityHidden(!showCompact)
                .accessibilityIdentifier("island-compact-row")
                .animation(appState.motion.content, value: showCompact)
                .zIndex(1)
            if !compact {
                let state = appState.currentState
                let layout = ExpandedLayout(appState: appState)
                IslandContentScope(state: state) {
                    expandedIslandLayout(for: state, layout: layout)
                }
                .id(state)
                .transition(.opacity.animation(appState.motion.feedback))
            }
        }
    }

    private struct SurfaceGeometry: Equatable {
        let state: IslandState
        let size: CGSize
        let topLeading: CGFloat
        let topTrailing: CGFloat
        let bottomLeading: CGFloat
        let bottomTrailing: CGFloat
        let outward: Bool
        let cutoutWidth: CGFloat
        let cutoutDepth: CGFloat
        let cutoutRadius: CGFloat
        @MainActor init(_ appState: AppState) {
            state = appState.currentState; size = appState.currentSize
            topLeading = appState.currentTopLeadingCornerRadius; topTrailing = appState.currentTopTrailingCornerRadius
            bottomLeading = appState.currentBottomLeadingCornerRadius; bottomTrailing = appState.currentBottomTrailingCornerRadius
            outward = appState.usesOutwardTopCorners
            cutoutWidth = appState.currentTopCutoutWidth; cutoutDepth = appState.currentTopCutoutDepth; cutoutRadius = appState.currentTopCutoutCornerRadius
        }
        var shape: PillShape {
            PillShape(topLeadingRadius: topLeading, topTrailingRadius: topTrailing,
                      bottomLeadingRadius: bottomLeading, bottomTrailingRadius: bottomTrailing, outwardTopCorners: outward,
                      topCutoutWidth: cutoutWidth, topCutoutDepth: cutoutDepth, topCutoutCornerRadius: cutoutRadius)
        }
    }
    private var targetSurface: SurfaceGeometry { SurfaceGeometry(appState) }

    private func transitionSurface(to target: SurfaceGeometry) {
        guard let previous = renderedSurface else {
            renderedSurface = target
            Task { @MainActor in appState.settleInitialSurface() }
            return
        }
        guard previous != target else { return }
        let animation = previous.state == target.state ? appState.motion.resize
            : target.state == .compact ? appState.motion.collapse : appState.motion.surface
        let token = appState.beginSurfaceMotion(owner: motionOwner)
        withAnimation(animation, completionCriteria: .removed) {
            renderedSurface = target
        } completion: {
            Task { @MainActor in appState.finishSurfaceMotion(owner: motionOwner, token: token) }
        }
    }

    // MARK: - Shape

    private var islandShape: PillShape {
        (renderedSurface ?? targetSurface).shape
    }

    // MARK: - Appearance

    // Shadows are intentionally disabled in the compact state. The island
    // panel is non-activating and sits in the transparent region around the
    // notch — any non-zero shadow pixel in that transparent region gets
    // captured by the panel's hit test and blocks clicks from reaching apps
    // underneath (see issue #1).
    private var ambientShadowOpacity: Double {
        appState.currentState == .compact ? 0.0 : 0.38
    }

    private var ambientShadowRadius: CGFloat {
        appState.currentState == .compact ? 0 : 8
    }

    private var ambientShadowYOffset: CGFloat {
        appState.currentState == .compact ? 0 : 6
    }

    private var keyShadowOpacity: Double {
        appState.currentState == .compact ? 0.0 : 0.58
    }

    private var keyShadowRadius: CGFloat {
        appState.currentState == .compact ? 0 : 14
    }

    private var keyShadowYOffset: CGFloat {
        appState.currentState == .compact ? 0 : 10
    }

    // MARK: - Expanded Layout

    private struct ExpandedLayout {
        let module: ActiveModule?
        let tab: FullExpandedTab
        let shoulderGap: CGFloat
        let size: CGSize
        let contentWidth: CGFloat
        let shoulderHeight: CGFloat
        let shoulder: Bool
        let horizontalPadding: CGFloat
        let topPadding: CGFloat
        let bottomPadding: CGFloat
        let scale: CGFloat
        let offset: CGFloat
        @MainActor init(appState: AppState) {
            module = appState.activeModule
            tab = appState.fullExpandedSelectedTab
            shoulderGap = appState.fullExpandedShoulderGapWidth
            size = appState.currentSize
            contentWidth = min(appState.currentContentSize.width, size.width)
            shoulderHeight = min(appState.currentContentTopInset, size.height)
            shoulder = appState.hasFullExpandedShoulderBarSpace
            horizontalPadding = appState.contentHorizontalPadding
            topPadding = appState.contentTopPadding
            bottomPadding = appState.contentBottomPadding
            scale = appState.expandedContentScale
            offset = appState.expandedContentTopOffset
        }
    }

    private func expandedIslandLayout(for state: IslandState, layout: ExpandedLayout) -> some View {
        let surfaceSize = layout.size
        let shoulderHeight = layout.shoulderHeight
        let contentWidth = layout.contentWidth
        let contentHeight = max(0, surfaceSize.height - shoulderHeight)

        return VStack(spacing: 0) {
            if layout.shoulder {
                FullExpandedTopBarView(layout: .shoulder, selectedTab: layout.tab,
                                       contentWidth: contentWidth, notchGap: layout.shoulderGap)
                    .environmentObject(appState)
                    .frame(
                        width: contentWidth,
                        height: shoulderHeight,
                        alignment: .top
                    )
                    .zIndex(1)
            } else {
                Color.clear
                    .frame(height: shoulderHeight)
            }

            currentExpandedContent(for: state, layout: layout)
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.top, layout.topPadding)
                .padding(.bottom, layout.bottomPadding)
                .frame(
                    width: contentWidth,
                    height: contentHeight,
                    alignment: .top
                )
                .clipped()

            Spacer(minLength: 0)
        }
        .frame(width: surfaceSize.width, height: surfaceSize.height, alignment: .top)
    }

    @ViewBuilder
    private func currentExpandedContent(for state: IslandState, layout: ExpandedLayout) -> some View {
        switch state {
        case .compact:
            EmptyView()
        case .expanded:
            ExpandedView(module: layout.module)
                .scaleEffect(layout.scale, anchor: .top)
                .padding(.top, layout.offset)
        case .fullExpanded:
            FullExpandedView(selectedTab: layout.tab, showsInlineBar: !layout.shoulder, shelf: shelf)
        }
    }

    // MARK: - Gestures

    private func handleSwipe(value: DragGesture.Value) {
        guard appState.canHandleIslandSurfaceGesture else { return }
        let horizontal = value.translation.width
        let vertical = value.translation.height
        let velocity = sqrt(pow(value.velocity.width, 2) + pow(value.velocity.height, 2))

        guard velocity > 35 || abs(horizontal) > 14 || abs(vertical) > 18 else { return }

        if abs(horizontal) > abs(vertical) {
            if appState.currentState != .compact {
                handleHorizontalSwipe(horizontal > 0 ? .right : .left)
            }
        } else {
            if vertical < 0 {
                if appState.currentState != .fullExpanded {
                    appState.open()
                }
            } else {
                appState.dismiss()
            }
        }
    }

    private func handleHorizontalSwipe(_ direction: SwipeDirection) {
        guard appState.canHandleIslandSurfaceGesture else { return }
        if appState.currentState == .expanded && appState.activeBuiltInModule == .nowPlaying {
            NowPlayingManager.shared.skipTrack(forward: direction == .left)
        } else {
            appState.cycleModule(forward: direction == .left)
        }
    }

    private func handleSurfaceTap() {
        guard appState.canHandleIslandSurfaceGesture else { return }
        if handleNotificationTapIfNeeded() {
            return
        }

        switch appState.currentState {
        case .compact, .expanded:
            if appState.compactPresentationModule == .builtIn(.nowPlaying) {
                appState.presentNowPlaying()
            } else if appState.compactPresentationModule == .builtIn(.tools) {
                appState.presentFullExpandedModule(.tools)
            } else {
                appState.open()
            }
        case .fullExpanded:
            break
        }
    }

    private func handleNotificationTapIfNeeded() -> Bool {
        guard appState.activeBuiltInModule == .notifications,
              let notification = NotificationManager.shared.latestNotification else {
            return false
        }

        if notification.tapAction != nil {
            NotificationManager.shared.activateNotification(notification)
            return true
        }

        if appState.currentState != .fullExpanded {
            appState.setActiveModule(.notifications, userInitiated: true)
            appState.fullyExpand()
            return true
        }

        return false
    }

    // MARK: - Shelf Drop

    private func handleShelfDropTargetChange(_ isTargeted: Bool) {
        guard appState.shelfEnabled else { return }

        if isTargeted {
            shelfDragEndWorkItem?.cancel()
            shelfDragEndWorkItem = nil
            appState.beginShelfDragPresentation(owner: motionOwner)
            return
        }

        let workItem = DispatchWorkItem {
            guard !isShelfDropTargeted else { return }
            appState.endShelfDragPresentation(owner: motionOwner)
            shelfDragEndWorkItem = nil
        }
        shelfDragEndWorkItem?.cancel()
        shelfDragEndWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
    }

}

private struct IslandSurfaceSwipeModifier: ViewModifier {
    let enabled: Bool
    let suppressGesture: Bool
    let isCompact: Bool
    let onTrackpad: (SwipeDirection) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onTrackpadSwipe { direction in
                    guard !isCompact else { return }
                    onTrackpad(direction)
                }
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onEnded { value in
                            onDragEnded(value)
                        },
                    including: suppressGesture ? .subviews : .all
                )
        } else {
            content
        }
    }
}
