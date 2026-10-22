import Foundation

enum HomeWidgetSelection: Hashable, Identifiable {
    case none
    case builtIn(ModuleType)

    init(rawValue: String) {
        if rawValue == Self.none.rawValue {
            self = .none
        } else if rawValue.hasPrefix("builtIn."),
                  let module = ModuleType(rawValue: String(rawValue.dropFirst("builtIn.".count))) {
            self = .builtIn(module)
        } else {
            self = .none
        }
    }

    var id: String { rawValue }

    var rawValue: String {
        switch self {
        case .none:
            return "none"
        case .builtIn(let module):
            return "builtIn.\(module.rawValue)"
        }
    }

    @MainActor
    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .builtIn(.nowPlaying):
            return "Media Player"
        case .builtIn(let module):
            return module.displayName
        }
    }

    var iconName: String {
        switch self {
        case .none:
            return "minus"
        case .builtIn(let module):
            return module.iconName
        }
    }
}
