import SwiftUI

/// One timing policy for surfaces, module swaps, artwork and control feedback.
struct IslandMotion {
    let speed: Double
    let reduced: Bool
    let bounce: Double

    private var scale: Double { 1 / max(0.5, min(2, speed.isFinite ? speed : 1)) }
    var surfaceDuration: Double { (reduced ? 0.1 : 0.22) * scale }
    var contentDuration: Double { (reduced ? 0.08 : 0.12) * scale }
    var surface: Animation {
        reduced ? .easeOut(duration: surfaceDuration)
            : .smooth(duration: surfaceDuration, extraBounce: min(max(bounce, 0), 0.05))
    }
    var content: Animation { .easeInOut(duration: contentDuration) }
    // A collapsing shell must never undershoot its final content width.
    var collapse: Animation { .easeOut(duration: (reduced ? 0.1 : 0.18) * scale) }
    var resize: Animation { .easeInOut(duration: (reduced ? 0.08 : 0.14) * scale) }
    var artwork: Animation { .easeInOut(duration: (reduced ? 0.1 : 0.22) * scale) }
    var feedback: Animation { .easeInOut(duration: (reduced ? 0.06 : 0.1) * scale) }
    var transition: AnyTransition {
        .opacity
    }
}

/// Each screen owns its own animation completion. Replaced callbacks cannot
/// finish a newer transition; the viewport stays open until every screen settles.
struct IslandTransitionCompletions {
    private var pending: [UUID: UUID] = [:]
    var isActive: Bool { !pending.isEmpty }
    mutating func begin(owner: UUID) -> UUID {
        let token = UUID()
        pending[owner] = token
        return token
    }
    mutating func finish(owner: UUID, token: UUID) -> Bool {
        guard pending[owner] == token else { return false }
        pending.removeValue(forKey: owner)
        return pending.isEmpty
    }
    mutating func remove(owner: UUID) -> Bool {
        guard pending.removeValue(forKey: owner) != nil else { return false }
        return pending.isEmpty
    }
}

/// Current host selection is separate from each outgoing view's captured selection.
struct IslandContentSelection: Equatable {
    let state: IslandState
    let module: ActiveModule?
    let tab: FullExpandedTab
}

private struct IslandContentSelectionKey: EnvironmentKey {
    static let defaultValue: IslandContentSelection? = nil
}
private struct IslandMotionKey: EnvironmentKey {
    static let defaultValue = IslandMotion(speed: 1, reduced: false, bounce: 0)
}
private struct PlaybackArtworkTrackKey: EnvironmentKey {
    static let defaultValue = ""
}
private struct PlaybackArtworkNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
private struct IslandPresentationStateKey: EnvironmentKey {
    static let defaultValue: IslandState? = nil
}
private struct IslandContentActiveKey: EnvironmentKey {
    static let defaultValue = true
}
extension EnvironmentValues {
    var islandContentSelection: IslandContentSelection? {
        get { self[IslandContentSelectionKey.self] }
        set { self[IslandContentSelectionKey.self] = newValue }
    }
    var islandMotion: IslandMotion {
        get { self[IslandMotionKey.self] }
        set { self[IslandMotionKey.self] = newValue }
    }
    var playbackArtworkTrackID: String {
        get { self[PlaybackArtworkTrackKey.self] }
        set { self[PlaybackArtworkTrackKey.self] = newValue }
    }
    var islandPresentationState: IslandState? {
        get { self[IslandPresentationStateKey.self] }
        set { self[IslandPresentationStateKey.self] = newValue }
    }
    var playbackArtworkNamespace: Namespace.ID? {
        get { self[PlaybackArtworkNamespaceKey.self] }
        set { self[PlaybackArtworkNamespaceKey.self] = newValue }
    }
    var islandContentActive: Bool {
        get { self[IslandContentActiveKey.self] }
        set { self[IslandContentActiveKey.self] = newValue }
    }
}

struct PlaybackArtworkGeometry: ViewModifier {
    @Environment(\.playbackArtworkNamespace) private var namespace
    @Environment(\.islandContentActive) private var active
    @Environment(\.islandMotion) private var motion
    @Environment(\.playbackArtworkTrackID) private var trackID

    @ViewBuilder func body(content: Content) -> some View {
        if let namespace, !motion.reduced, !trackID.isEmpty {
            content.matchedGeometryEffect(id: "music-artwork-" + trackID,
                                          in: namespace, properties: .frame, isSource: active)
        } else {
            content
        }
    }
}

/// Removing content may remain visible until its transition completes. It must
/// immediately stop accepting events (including keyboard/AX) and view-owned work.
struct IslandContentScope<Content: View>: View {
    @Environment(\.islandContentSelection) private var selection
    @Environment(\.islandContentActive) private var parentActive
    let state: IslandState
    var module: ActiveModule? = nil
    var tab: FullExpandedTab? = nil
    @ViewBuilder var content: () -> Content

    private var active: Bool {
        guard parentActive, let selection, selection.state == state else { return false }
        if let tab { return selection.tab == tab }
        if let module { return selection.module == module }
        return true
    }

    var body: some View {
        content()
            .environment(\.islandContentActive, active)
            .environment(\.islandPresentationState, state)
            .allowsHitTesting(active)
            .disabled(!active)
            .accessibilityHidden(!active)
    }
}
