import SwiftUI

struct HomeScreenView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let panels = visiblePanels

        Group {
            switch panels.count {
            case 0:
                HomeEmptyState(
                    icon: "square.grid.2x2",
                    title: Text("No home modules enabled"),
                    subtitle: Text("Enable modules in Settings to show them here."),
                    fillsAvailableSpace: true
                )
            case 3:
                threePanelLayout
            default:
                evenLayout(panels: panels)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var visiblePanels: [HomePanel] {
        appState.homePanels
    }

    private var threePanelLayout: some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(visiblePanels.enumerated()), id: \.element.id) { index, panel in
                panelView(for: panel)
                    .frame(width: preferredWidth(for: panel), alignment: .topLeading)
                    .frame(maxWidth: panel == .calendar ? .infinity : nil, alignment: .topLeading)

                if index < visiblePanels.count - 1 {
                    homeDivider
                }
            }
        }
    }

    private func evenLayout(panels: [HomePanel]) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ForEach(Array(panels.enumerated()), id: \.element.id) { index, panel in
                panelView(for: panel)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                if index < panels.count - 1 {
                    homeDivider
                }
            }
        }
    }

    @ViewBuilder
    private func panelView(for panel: HomePanel) -> some View {
        switch panel {
        case .none:
            EmptyView()
        case .nowPlaying:
            HomeNowPlayingPanel()
        case .calendar:
            HomeCalendarPanel()
        case .weather:
            HomeWeatherPanel(preferences: appState.weatherPreferences)
        }
    }

    private var homeDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    private func preferredWidth(for panel: HomePanel) -> CGFloat? {
        switch panel {
        case .nowPlaying:
            return visiblePanels.count == 3 ? 228 : nil
        case .weather:
            return visiblePanels.count == 3 ? 150 : nil
        case .calendar, .none:
            return nil
        }
    }
}

/// Rendering receives values and actions; it does not start players or observe global state.
struct HomeMusicPresentation {
    var title: String
    var subtitle: String
    var isPlaying: Bool
    var canControlPlayback: Bool
    var progress: Double
    var elapsedText: String
    var durationText: String
    var emptyTitle: String = ""
    var emptySubtitle: String = ""
    var albumArt: NSImage? = nil
    var sourceAppIcon: NSImage? = nil
    var duration: TimeInterval = 0
    var canSeek = false
    var isSeeking = false
    var trackID = ""
    var sourceName = ""
    var canOpenPlayer = false
    var shuffleMode: PlaybackShuffleMode?
    var repeatMode: PlaybackRepeatMode?
    var favoriteContext: String?
    var isControlPending = false
    var isPresentationPending = false
    var canChangeMode = false
    var artworkGlowEnabled = true
    var reduceAnimations = false
    var contentAnimation: Animation? = nil
    var feedbackAnimation: Animation? = nil
}

extension HomeMusicPresentation {
    @MainActor init(manager: NowPlayingManager, appState: AppState) {
        let secondaryLine = [manager.artist, manager.album].filter { !$0.isEmpty }.joined(separator: " · ")
        self.init(title: manager.title,
                  subtitle: manager.playbackStatusDescription ?? (secondaryLine.isEmpty ? L10n.text("Media") : secondaryLine),
                  isPlaying: manager.isPlaying, canControlPlayback: manager.canControlPlayback,
                  progress: manager.progress, elapsedText: manager.formattedElapsedTime,
                  durationText: manager.formattedDuration, emptyTitle: manager.emptyTitle,
                  emptySubtitle: manager.emptySubtitle, albumArt: manager.albumArt, sourceAppIcon: manager.sourceAppIcon,
                  duration: manager.duration, canSeek: manager.canSeek, isSeeking: manager.isSeeking,
                  trackID: manager.presentationTrackID, sourceName: manager.sourceName,
                  canOpenPlayer: manager.canOpenCurrentPlayer, shuffleMode: manager.shuffleMode,
                  repeatMode: manager.repeatMode, favoriteContext: manager.favoriteContext, isControlPending: manager.isControlPending, isPresentationPending: manager.isPresentationPending, canChangeMode: manager.canChangePlaybackMode,
                  artworkGlowEnabled: appState.musicArtworkGlowEnabled,
                  reduceAnimations: appState.shouldReduceAnimations,
                  contentAnimation: appState.contentSwapAnimation,
                  feedbackAnimation: appState.motion.feedback)
    }
}

struct HomeNowPlayingPanel: View {
    @ObservedObject private var manager = NowPlayingManager.shared
    @EnvironmentObject private var appState: AppState
    var isDetailed = false

    var body: some View {
        HomeNowPlayingContent(data: HomeMusicPresentation(manager: manager, appState: appState), isDetailed: isDetailed,
            previousTrack: { interact(manager.previousTrack) }, togglePlayPause: { interact(manager.togglePlayPause) },
            nextTrack: { interact(manager.nextTrack) }, seek: { manager.seek(to: manager.duration * $0) },
            openPlayer: { manager.openCurrentPlayer(fromIsland: appState) }, openPlayback: appState.presentNowPlaying,
            toggleShuffle: { interact(manager.toggleShuffle) }, cycleRepeat: { interact(manager.cycleRepeatMode) },
            beginInteraction: { appState.beginCompactControlInteraction() })
    }

    private func interact(_ action: () -> Void) {
        appState.beginCompactControlInteraction()
        action()
    }
}

/// Shared composition for the Home card and the full playback page. Controls
/// stay in place across track changes; only confirmed metadata fades between songs.
struct HomeNowPlayingContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let data: HomeMusicPresentation
    var isDetailed = false
    var previousTrack: () -> Void = {}
    var togglePlayPause: () -> Void = {}
    var nextTrack: () -> Void = {}
    var seek: (Double) -> Void = { _ in }
    var openPlayer: () -> Void = {}
    var openPlayback: () -> Void = {}
    var toggleShuffle: () -> Void = {}
    var cycleRepeat: () -> Void = {}
    var beginInteraction: () -> Void = {}

    private var trackAnimation: Animation? {
        reduceMotion || data.reduceAnimations ? .easeOut(duration: 0.1) : data.contentAnimation
    }

    var body: some View {
        Group {
            if data.title.isEmpty {
                HomeEmptyState(icon: "music.note.house", title: Text(data.emptyTitle), subtitle: Text(data.emptySubtitle))
            } else if isDetailed {
                HStack(spacing: 24) {
                    artwork(size: 112)
                    VStack(alignment: .leading, spacing: 8) {
                        metadata
                        seekBar
                        HStack {
                            controlsRow
                            Spacer(minLength: 8)
                            Button(action: openPlayer) {
                                Label(data.sourceName, systemImage: "arrow.up.forward.app")
                                    .font(.caption)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .disabled(!data.canOpenPlayer)
                            .help(L10n.format("Open %@", data.sourceName))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    metadata
                    HStack(spacing: 18) {
                        artwork(size: 68)
                        controlsRow.frame(maxWidth: .infinity)
                    }
                    seekBar
                }
            }
        }
    }

    private var metadata: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: 2) {
                if isDetailed {
                    titleLabel
                } else {
                    Button(action: openPlayback) {
                        HStack(spacing: 4) {
                            titleLabel
                            Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .help(L10n.text("Open playback page"))
                }
                Text(data.subtitle)
                    .font(HomeTypography.secondaryFont)
                    .foregroundStyle(HomeTypography.secondaryText)
                    .lineLimit(1)
                    .help(data.subtitle)
            }
            .id(data.trackID + "||" + data.title)
            .transition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(trackAnimation, value: data.trackID + "||" + data.title)
    }

    private var titleLabel: some View {
        Text(data.title)
            .font(isDetailed ? .system(size: 16, weight: .semibold) : HomeTypography.panelTitleFont)
            .foregroundStyle(HomeTypography.primaryText)
            .lineLimit(1)
            .help(data.title)
    }

    private func artwork(size: CGFloat) -> some View {
        ZStack {
            Button(action: openPlayer) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtView(image: data.albumArt, size: size, glowEnabled: data.artworkGlowEnabled)
                    if let icon = data.sourceAppIcon {
                        Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .offset(x: 3, y: 3)
                    }
                }
                .frame(width: size, height: size)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!data.canOpenPlayer)
            .help(L10n.format("Open %@", data.sourceName))
            .accessibilityLabel(L10n.format("Open %@", data.sourceName))
        }
        .frame(width: size, height: size)
    }

    private var seekBar: some View {
        PlaybackSeekBar(progress: data.progress, duration: data.duration, elapsedText: data.elapsedText,
                        durationText: data.durationText, canSeek: data.canSeek, isSeeking: data.isSeeking,
                        trackID: data.trackID, onSeek: seek)
    }

    private var controlsRow: some View {
        HStack(spacing: 10) {
            if isDetailed, let context = data.favoriteContext {
                PlaybackFavoriteButton(context: context, controlsPending: data.isControlPending || data.isPresentationPending, beginInteraction: beginInteraction)
                    .padding(.trailing, 10)
            }
            if isDetailed, let mode = data.shuffleMode {
                Button(action: toggleShuffle) {
                    Image(systemName: "shuffle").foregroundStyle(mode == .off ? .secondary : .primary)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!data.canChangeMode)
                .help(shuffleDescription(mode))
                .accessibilityLabel(L10n.text("Shuffle"))
            }
            transportButton("backward.fill", label: "Previous track", action: previousTrack)
            transportButton(data.isPlaying ? "pause.fill" : "play.fill",
                            label: data.isPlaying ? "Pause" : "Play", action: togglePlayPause)
            transportButton("forward.fill", label: "Next track", action: nextTrack)
            if isDetailed, let mode = data.repeatMode {
                Button(action: cycleRepeat) {
                    Image(systemName: mode == .track ? "repeat.1" : "repeat")
                        .foregroundStyle(mode == .off ? .secondary : .primary)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!data.canChangeMode)
                .help(repeatDescription(mode))
                .accessibilityLabel(repeatDescription(mode))
            }
        }
        .disabled(!data.canControlPlayback && !data.isControlPending)
        .allowsHitTesting(!data.isControlPending)
    }

    private func transportButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                Image(systemName: symbol)
                    .id(symbol)
                    .transition(.opacity)
            }
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
            .animation(reduceMotion || data.reduceAnimations ? .easeOut(duration: 0.08) : data.feedbackAnimation, value: symbol)
        }
        .buttonStyle(.plain)
        .help(L10n.text(label))
        .accessibilityLabel(L10n.text(label))
    }

    private func repeatDescription(_ mode: PlaybackRepeatMode) -> String {
        switch mode {
        case .off: return L10n.text("Repeat off — repeat all next")
        case .playlist: return L10n.text("Repeat all — repeat one next")
        case .track: return L10n.text("Repeat one — turn repeat off next")
        }
    }

    private func shuffleDescription(_ mode: PlaybackShuffleMode) -> String {
        switch mode {
        case .off: return L10n.text("Shuffle off — enable shuffle")
        case .albums: return L10n.text("Shuffle albums — disable shuffle")
        case .tracks: return L10n.text("Shuffle tracks — disable shuffle")
        }
    }
}

private struct HomeCalendarPanel: View {
    @ObservedObject private var manager = CalendarManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(todayTitle)
                    .font(HomeTypography.heroFont)
                    .foregroundStyle(HomeTypography.primaryText)
                    .lineLimit(2)

                Text(todaySubtitle)
                    .font(HomeTypography.secondaryFont)
                    .foregroundStyle(HomeTypography.secondaryText)
            }

            if upcomingEvents.isEmpty {
                HomeEmptyState(
                    icon: "calendar",
                    title: Text("Nothing coming up"),
                    subtitle: Text("Your schedule is clear for now.")
                )
            } else {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(upcomingEvents.prefix(3).enumerated()), id: \.offset) { _, event in
                        HomeEventRow(
                            event: event,
                            countdown: countdown(for: event),
                            joinURL: manager.joinURL(for: event)
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var upcomingEvents: [CalendarEventSnapshot] {
        let now = Date()
        return manager.todayEvents.filter { $0.endDate > now }
    }

    private var todayTitle: String {
        CalendarPresentation.formatted(Date(), template: "EEE d MMM")
    }

    private var todaySubtitle: String {
        if upcomingEvents.isEmpty {
            return L10n.text("No events scheduled today")
        }
        if upcomingEvents.count == 1 {
            return L10n.text("1 event coming up")
        }
        return L10n.format("%d events coming up", upcomingEvents.count)
    }

    private func countdown(for event: CalendarEventSnapshot) -> String? {
        guard let nextEvent = manager.nextEvent, nextEvent.eventIdentifier == event.eventIdentifier else {
            return nil
        }
        return manager.nextEventCountdown
    }

}

private struct HomeWeatherPanel: View {
    @ObservedObject private var manager = WeatherManager.shared
    @ObservedObject var preferences: WeatherPreferences

    private func formattedTemp(_ celsius: Double) -> String {
        preferences.temperatureUnit.formatted(celsius, showsUnit: false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WeatherFreshnessView(manager: manager)
            if isWeatherUnavailable {
                HomeEmptyState(
                    icon: "cloud.sun",
                    title: manager.isLoading ? Text("Fetching weather") : Text("Weather unavailable"),
                    subtitle: manager.isLoading ? Text("Getting your local conditions.") : Text(manager.errorMessage ?? L10n.text("Allow location access to fetch local weather."))
                )
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: manager.weather.conditionIcon)
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.92))
                            .frame(width: 34, height: 34)
                            .background(
                                Circle()
                                    .fill(Color.white.opacity(0.06))
                            )

                        VStack(alignment: .leading, spacing: 1) {
                            Text(formattedTemp(manager.weather.temperature))
                                .font(HomeTypography.temperatureFont)
                                .foregroundStyle(HomeTypography.primaryText)

                            Text(manager.weather.condition)
                                .font(HomeTypography.secondaryFont)
                                .foregroundStyle(HomeTypography.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    if !manager.weather.locationName.isEmpty {
                        Text(manager.weather.locationName)
                            .font(HomeTypography.bodyTitleFont)
                            .foregroundStyle(HomeTypography.secondaryText)
                            .lineLimit(1)
                    }

                    HStack(spacing: 8) {
                        weatherStat(
                            title: Text("High"),
                            value: formattedTemp(manager.weather.temperatureHigh),
                            icon: "arrow.up.circle.fill",
                            tint: Color.orange.opacity(0.88)
                        )
                        weatherStat(
                            title: Text("Low"),
                            value: formattedTemp(manager.weather.temperatureLow),
                            icon: "arrow.down.circle.fill",
                            tint: Color.cyan.opacity(0.88)
                        )
                    }
                }
            }
        }
    }

    private var isWeatherUnavailable: Bool {
        !hasWeatherData
    }

    private var hasWeatherData: Bool {
        manager.hasWeatherData
    }

    private func weatherStat(title: Text, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)

                title
                    .font(HomeTypography.badgeFont)
                    .foregroundStyle(HomeTypography.tertiaryText)
            }

            Text(value)
                .font(HomeTypography.valueFont)
                .foregroundStyle(HomeTypography.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HomeEventRow: View {
    @EnvironmentObject private var appState: AppState
    let event: CalendarEventSnapshot
    let countdown: String?
    let joinURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color(cgColor: event.calendar.color))
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title ?? L10n.text("Upcoming event"))
                    .font(HomeTypography.bodyTitleFont)
                    .foregroundStyle(HomeTypography.secondaryText)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(timeRange)
                        .font(HomeTypography.secondaryFont)
                        .foregroundStyle(HomeTypography.secondaryText)
                        .lineLimit(1)

                    if let countdown {
                        Text(countdown)
                            .font(HomeTypography.badgeFont)
                            .foregroundStyle(HomeTypography.primaryText.opacity(0.92))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                }
            }

            Spacer(minLength: 0)

            if let joinURL {
                Button {
                    appState.openExternalURL(joinURL, for: .calendar)
                } label: {
                    Image(systemName: "video.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.06))
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var timeRange: String {
        CalendarPresentation.timeRange(start: event.startDate, end: event.endDate)
    }
}

private struct HomeEmptyState: View {
    let icon: String
    // Keep localized keys distinct from already-localized provider messages.
    let title: Text
    let subtitle: Text
    var fillsAvailableSpace = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(HomeTypography.tertiaryText)
                .padding(.bottom, 2)

            title
                .font(HomeTypography.bodyTitleFont)
                .foregroundStyle(HomeTypography.primaryText.opacity(0.9))

            subtitle
                .font(HomeTypography.secondaryFont)
                .foregroundStyle(HomeTypography.secondaryText)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: fillsAvailableSpace ? .infinity : nil,
            alignment: .center
        )
    }
}

private enum HomeTypography {
    static let heroFont = Font.system(size: 18, weight: .semibold)
    static let temperatureFont = Font.system(size: 24, weight: .semibold)
    static let panelTitleFont = Font.system(size: 15, weight: .semibold)
    static let bodyTitleFont = Font.system(size: 14, weight: .semibold)
    static let valueFont = Font.system(size: 14, weight: .semibold)
    static let secondaryFont = Font.system(size: 11, weight: .medium)
    static let badgeFont = Font.system(size: 10, weight: .semibold)
    static let metaFont = Font.system(size: 10, weight: .medium, design: .monospaced)

    static let primaryText = Color.white.opacity(0.88)
    static let secondaryText = Color.white.opacity(0.58)
    static let tertiaryText = Color.white.opacity(0.36)
}
