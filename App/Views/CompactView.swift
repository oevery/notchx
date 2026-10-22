import SwiftUI

struct CompactView: View {
    @EnvironmentObject var appState: AppState
    let module: ActiveModule?
    let minimal: Bool

    var body: some View {
        ZStack {
            if let module {
                IslandContentScope(state: .compact, module: module) {
                    Group {
                        if minimal { minimalCompactContent(for: module).padding(.horizontal, appState.compactSideCornerInset) }
                        else { standardCompactContent(for: module) }
                    }
                }
                .id(module)
                .transition(appState.motion.transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay(alignment: .trailing) { PendingIslandEventsMenu().padding(.trailing, 4) }
        .animation(appState.contentSwapAnimation, value: module)
    }

    private func horizontalPadding(for module: ActiveModule) -> CGFloat {
        let isNowPlayingActive = module == .builtIn(.nowPlaying)
        let base: CGFloat = isNowPlayingActive ? 4 : 12
        // On non-notch Macs, add padding to keep content within the arch walls.
        if appState.usesWideCompactLayout {
            return base + Constants.compactCornerRadius
        }
        return base
    }

    private func standardCompactContent(for module: ActiveModule) -> some View {
        HStack(spacing: 8) {
            switch module {
            case .builtIn(.nowPlaying):
                NowPlayingCompactView()
            case .builtIn(.volumeHUD):
                SystemHUDCompactView()
            case .builtIn(.battery):
                BatteryCompactView()
            case .builtIn(.shelf):
                ShelfCompactView()
            case .builtIn(.connectivity):
                ConnectivityCompactView()
            case .builtIn(.calendar):
                CalendarCompactView()
            case .builtIn(.weather):
                WeatherCompactView(preferences: appState.weatherPreferences)
            case .builtIn(.notifications):
                NotificationCompactView()
            case .builtIn(.teleprompter):
                TeleprompterCompactView()
            case .builtIn(.agent):
                AgentCompactView()
            case .builtIn(.tools):
                ToolsCompactView()
            }
        }
        .padding(.horizontal, horizontalPadding(for: module))
    }

    @ViewBuilder
    private func minimalCompactContent(for module: ActiveModule) -> some View {
        switch module {
        case .builtIn(.nowPlaying):
            CompactSideSlots(
                centerGapWidth: appState.compactMinimalCenterGapWidth,
                sideWidth: appState.compactSideSlotWidth,
                leading: AnyView(NowPlayingMinimalCompactAlbumView()),
                trailing: AnyView(NowPlayingMinimalCompactPlaybackView())
            )
        case .builtIn(.agent):
            CompactSideSlots(centerGapWidth: appState.compactMinimalCenterGapWidth,
                sideWidth: appState.compactSideSlotWidth,
                leading: AnyView(AgentCompactLeadingView()), trailing: AnyView(AgentCompactCountView()))
        case .builtIn(.tools):
            CompactSideSlots(centerGapWidth: appState.compactMinimalCenterGapWidth,
                sideWidth: appState.compactSideSlotWidth,
                leading: AnyView(KeepAwakeCompactIcon()), trailing: AnyView(KeepAwakeCompactCountdown()))
        default:
            standardCompactContent(for: module)
        }
    }
}

/// One geometry contract for the host's camera gap, music, and agent content.
/// A module supplies content only; each side is centered in the host's slot.
private struct CompactSideSlotWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    fileprivate var compactSideSlotWidth: CGFloat? {
        get { self[CompactSideSlotWidthKey.self] }
        set { self[CompactSideSlotWidthKey.self] = newValue }
    }
}

struct CompactSideSlots: View {
    let centerGapWidth: CGFloat
    var sideWidth: CGFloat = Constants.compactSideWidth
    let leading: AnyView
    let trailing: AnyView

    var body: some View {
        HStack(spacing: 0) {
            leading
                .frame(width: sideWidth, alignment: .center)
                .frame(maxHeight: .infinity, alignment: .center)
                .environment(\.compactSideSlotWidth, sideWidth)

            Color.clear
                .frame(width: centerGapWidth)

            trailing
                .frame(width: sideWidth, alignment: .center)
                .frame(maxHeight: .infinity, alignment: .center)
                .environment(\.compactSideSlotWidth, sideWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Shared content canvas and optical inset. Callers receive the display size;
/// brand marks cannot change slot geometry or move their own center.
struct CompactSlot<Content: View>: View {
    @Environment(\.compactSideSlotWidth) private var sideWidth
    enum Kind { case artwork, brand, indicator }
    let kind: Kind
    @ViewBuilder let content: (CGFloat) -> Content

    private var displaySize: CGFloat {
        kind == .brand ? min(Constants.compactSlotBrandSize, canvasSize) : canvasSize
    }
    private let canvasSize = Constants.compactSlotContentSize

    var body: some View {
        content(displaySize)
            .frame(width: displaySize, height: displaySize, alignment: .center)
            .frame(width: canvasSize, height: canvasSize, alignment: .center)
            .frame(width: sideWidth ?? canvasSize, alignment: .center)
            .frame(maxHeight: sideWidth == nil ? nil : .infinity, alignment: .center)
            .contentShape(Rectangle())
    }
}

struct CompactSlotCount: View {
    let count: Int
    var body: some View {
        CompactSlot(kind: .indicator) { _ in
            Text(count > 99 ? "99+" : String(max(0, count)))
                .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white)
        }
    }
}

private struct NowPlayingMinimalCompactAlbumView: View {
    @ObservedObject private var manager = NowPlayingManager.shared

    var body: some View {
        CompactSlot(kind: .artwork) { size in
            PlaybackArtworkImage(image: manager.albumArt, size: size, cornerRadius: Constants.compactArtworkCornerRadius)
        }
    }
}

private struct NowPlayingMinimalCompactPlaybackView: View {
    var body: some View {
        NowPlayingPlaybackCompactButton()
    }
}
