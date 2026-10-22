import Foundation

enum ModuleOrder {
    static let key = "modules.displayOrder"

    static func resolve(_ raw: String) -> [ModuleType] {
        var seen = Set<ModuleType>()
        let saved = raw.split(separator: ",").compactMap { ModuleType(rawValue: String($0)) }
        return (saved + ModuleType.allCases).filter { seen.insert($0).inserted }
    }
}
