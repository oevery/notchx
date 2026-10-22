import SwiftUI
import AppKit

enum SettingsPane: Hashable, Identifiable {
    case general, modules, home, appearance, advanced
    case module(ModuleType)
    init?(id: String) {
        switch id {
        case "general": self = .general
        case "modules": self = .modules
        case "home": self = .home
        case "appearance": self = .appearance
        case "advanced": self = .advanced
        default:
            guard id.hasPrefix("module."), let module = ModuleType(rawValue: String(id.dropFirst(7))) else { return nil }
            self = .module(module)
        }
    }
    var id: String {
        switch self {
        case .module(let module): return "module.\(module.rawValue)"
        case .general: return "general"
        case .modules: return "modules"
        case .home: return "home"
        case .appearance: return "appearance"
        case .advanced: return "advanced"
        }
    }
    var title: String {
        switch self {
        case .general: return L10n.text("General")
        case .modules: return L10n.text("Module management")
        case .home: return L10n.text("Home layout")
        case .appearance: return L10n.text("Appearance")
        case .advanced: return L10n.text("Advanced")
        case .module(let module): return L10n.text(module.title)
        }
    }
    var icon: String {
        switch self {
        case .general: return "gear"
        case .modules: return "square.grid.2x2"
        case .home: return "rectangle.split.3x1"
        case .appearance: return "paintbrush"
        case .advanced: return "wrench.and.screwdriver"
        case .module(let module): return module.icon
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var navigation = SettingsNavigation.shared
    private var selectedPane: SettingsPane? { navigation.selectedPane }
    var body: some View {
        // A fixed sibling sidebar cannot be hidden by NavigationSplitView's toggle.
        HStack(spacing: 0) {
            List(selection: $navigation.selectedPane) {
                ForEach([SettingsPane.general, .home, .appearance, .advanced]) { pane in
                    Label(pane.title, systemImage: pane.icon).tag(pane)
                }
                Section(L10n.text("Modules")) {
                    Label(SettingsPane.modules.title, systemImage: SettingsPane.modules.icon)
                        .tag(SettingsPane.modules)
                    ForEach(appState.orderedModules) { module in
                        Label(L10n.text(module.title), systemImage: module.icon)
                            .tag(SettingsPane.module(module))
                    }
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, 12)
                    HStack {
                        Button(L10n.text("Quit NotchX")) { NSApp.terminate(nil) }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 16)
                }
            }
            // Include the bottom inset so the marker matches the native scroll view.
            .stableNativeScrollLayout()
            .frame(width: 200)
            Divider()
            StableScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if case .module = selectedPane ?? .general {} else {
                        SettingPageHeader(title: (selectedPane ?? .general).title)
                    }
                    detailContent
                }
                    .frame(maxWidth: 760, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(selectedPane)
        }
        .frame(minWidth: 800, idealWidth: 960, minHeight: 560, idealHeight: 680)
        .environment(\.islandMotion, appState.motion)
        .notchXLocalized()
    }
    @ViewBuilder private var detailContent: some View {
        switch selectedPane ?? .general {
        case .general: GeneralSettingsView()
        case .modules:
            ModuleSettingsView(appState: appState) { module in navigation.selectedPane = .module(module) }
        case .module(let module): ModuleDetailSettingsView(module: module, appState: appState)
        case .home: HomeLayoutSettingsView()
        case .appearance: AppearanceSettingsView(appState: appState)
        case .advanced: AdvancedSettingsView()
        }
    }
}
