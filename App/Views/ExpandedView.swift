import SwiftUI

struct ExpandedView: View {
    @EnvironmentObject var appState: AppState
    let module: ActiveModule?

    var body: some View {
        ZStack(alignment: .top) {
            if let module {
                IslandContentScope(state: .expanded, module: module) {
                    Group {
                        switch module {
                        case .builtIn(.nowPlaying):
                            NowPlayingExpandedView()
                        case .builtIn(.volumeHUD):
                            SystemHUDExpandedView()
                        case .builtIn(.battery):
                            BatteryExpandedView()
                        case .builtIn(.shelf):
                            ShelfExpandedView()
                        case .builtIn(.connectivity):
                            ConnectivityExpandedView()
                        case .builtIn(.calendar):
                            CalendarExpandedView()
                        case .builtIn(.weather):
                            WeatherExpandedView(preferences: appState.weatherPreferences)
                        case .builtIn(.notifications):
                            NotificationExpandedView()
                        case .builtIn(.teleprompter):
                            TeleprompterExpandedView()
                        case .builtIn(.agent):
                            AgentExpandedView()
                        case .builtIn(.tools):
                            ToolsExpandedView()
                        }
                    }
                    .padding(.horizontal, module == .builtIn(.nowPlaying) ? 4 : 8)
                }
                .id(module)
                .transition(appState.motion.transition)
            } else {
                // Default expanded view - show quick summary
                HStack(spacing: 16) {
                    ModuleSummaryItem(icon: "battery.100", label: Text("Battery"))
                    ModuleSummaryItem(icon: "music.note", label: Text("Music"))
                    ModuleSummaryItem(icon: "calendar", label: Text("Calendar"))
                    ModuleSummaryItem(icon: "tray.full.fill", label: Text("Shelf"))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 8)
            }
        }
        .animation(appState.contentSwapAnimation, value: module)
        .padding(.vertical, 2)
        .overlay(alignment: .bottomTrailing) { PendingIslandEventsMenu().padding(2) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct ModuleSummaryItem: View {
    let icon: String
    let label: Text

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 18))
            label
                .font(.system(size: 9, weight: .medium))
        }
        .foregroundColor(.white.opacity(0.7))
    }
}
