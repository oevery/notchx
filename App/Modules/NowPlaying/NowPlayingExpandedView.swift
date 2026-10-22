import SwiftUI

struct NowPlayingExpandedView: View {
    @ObservedObject private var manager = NowPlayingManager.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.islandPresentationState) private var presentationState

    var body: some View {
        if (presentationState ?? appState.currentState) == .fullExpanded {
            HomeNowPlayingPanel(isDetailed: true)
        } else {
            HStack(spacing: 12) {
                NowPlayingSourceButton {
                    AlbumArtView(image: manager.albumArt, size: 56, glowEnabled: appState.musicArtworkGlowEnabled)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Button(action: appState.presentNowPlaying) {
                        Text(manager.title)
                            .contentTransition(.opacity)
                            .animation(appState.contentSwapAnimation, value: manager.title)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Open playback page"))
                    Text(manager.playbackStatusDescription ?? manager.artist)
                        .contentTransition(.opacity)
                        .animation(appState.contentSwapAnimation, value: manager.artist)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    PlaybackSeekBar(progress: manager.progress, duration: manager.duration,
                                    elapsedText: manager.formattedElapsedTime, durationText: manager.formattedDuration,
                                    canSeek: manager.canSeek, isSeeking: manager.isSeeking,
                                    trackID: manager.presentationTrackID, showsTimes: false) {
                        manager.seek(to: manager.duration * $0)
                    }
                }
                Button(action: manager.togglePlayPause) {
                    Image(systemName: manager.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.opacity)
                        .animation(appState.motion.feedback, value: manager.isPlaying)
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .disabled(!manager.hasControllableTrack)
                .allowsHitTesting(!manager.isControlPending)
            }
            .foregroundStyle(.white)
        }
    }
}

struct NowPlayingSourceButton<Label: View>: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var manager = NowPlayingManager.shared
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button {
            appState.beginCompactControlInteraction()
            manager.openCurrentPlayer(fromIsland: appState)
        } label: { label() }
        .buttonStyle(.plain)
        .disabled(!manager.canOpenCurrentPlayer)
        .help(L10n.format("Open %@", manager.sourceName))
        .accessibilityLabel(L10n.format("Open %@", manager.sourceName))
    }
}

/// One native slider for Home, the hover card and the playback page. Dragging
/// owns only a local preview; the manager owns pending and confirmed positions.
struct PlaybackSeekBar: View {
    @EnvironmentObject private var appState: AppState
    let progress: Double
    let duration: TimeInterval
    let elapsedText: String
    let durationText: String
    let canSeek: Bool
    let isSeeking: Bool
    let trackID: String
    var showsTimes = true
    var onSeek: (Double) -> Void

    @State private var draggedProgress: Double?
    @State private var editingTrackID: String?
    @State private var interaction: IslandInteractionToken?
    @Environment(\.islandContentActive) private var contentActive

    var body: some View {
        VStack(spacing: 0) {
            Slider(value: Binding(
                get: { min(1, max(0, draggedProgress ?? progress)) },
                set: { draggedProgress = $0 }
            ), in: 0...1, onEditingChanged: editingChanged)
            .controlSize(.small)
            .tint(Color(white: 0.9))
            .disabled(!canSeek)
            .accessibilityLabel(L10n.text("Playback position"))
            .accessibilityValue(draggedProgress.map { formattedTime($0 * duration) } ?? elapsedText)
            if showsTimes {
                HStack {
                    Text(draggedProgress.map { formattedTime($0 * duration) } ?? elapsedText)
                    Spacer(minLength: 4)
                    if isSeeking { Text(L10n.text("Seeking…")) }
                    Spacer(minLength: 4)
                    Text(durationText)
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .onChange(of: trackID) { _, _ in endEditing() }
        .onChange(of: canSeek) { _, enabled in if !enabled { endEditing() } }
        .onChange(of: contentActive) { _, active in if !active { endEditing() } }
        .onDisappear { endEditing() }
    }

    private func editingChanged(_ editing: Bool) {
        if editing {
            editingTrackID = trackID
            if draggedProgress == nil { draggedProgress = progress }
            if interaction == nil { interaction = appState.beginControlInteraction(for: .nowPlaying) }
        } else {
            if editingTrackID == trackID, canSeek, let draggedProgress { onSeek(draggedProgress) }
            endEditing()
        }
    }

    private func endEditing() {
        let wasEditing = editingTrackID != nil
        editingTrackID = nil
        draggedProgress = nil
        if wasEditing {
            if let interaction { appState.endControlInteraction(interaction) }
            interaction = nil
            // The containing surface may receive its gesture-end after the
            // slider. Keep that release from switching pages or dismissing.
            appState.beginCompactControlInteraction(timeout: 0.25)
        }
    }

    private func formattedTime(_ value: TimeInterval) -> String {
        guard value.isFinite else { return "—:—" }
        let seconds = Int(max(0, value))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
