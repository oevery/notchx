import AppKit

/// Only compiled-in native modules can participate in host presentation.
enum ActiveModule: Equatable, Hashable {
    case builtIn(ModuleType)

    var displayName: String {
        switch self {
        case .builtIn(let module): return module.displayName
        }
    }

    var iconName: String {
        switch self {
        case .builtIn(let module): return module.iconName
        }
    }

    var iconImage: NSImage? { nil }
}
