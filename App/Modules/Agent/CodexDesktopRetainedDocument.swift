import Foundation

/// Keeps protocol positions without keeping old turn payloads. Opaque nodes
/// accept irrelevant descendant changes but never become visible evidence.
struct CodexDesktopRetainedDocument {
    private enum Component: Equatable { case key(String), index(Int) }
    private struct Node {
        indirect enum Body {
            case object([String: Node]), array([Node]), value(Any), opaque
        }
        var body: Body
        var bytes: Int
        var nodes: Int
        static let opaque = Node(body: .opaque, bytes: 8, nodes: 1)

        init(_ value: Any) throws {
            if value is NSNull { self = .opaque }
            else if let object = value as? [String: Any] {
                let children = try object.mapValues { try Node($0) }
                body = .object(children)
                bytes = children.reduce(16) { $0 + $1.key.utf8.count + $1.value.bytes + 16 }
                nodes = 1 + children.values.reduce(0) { $0 + $1.nodes }
            } else if let array = value as? [Any] {
                let children = try array.map { try Node($0) }
                body = .array(children); bytes = 16 + children.reduce(0) { $0 + $1.bytes + 8 }
                nodes = 1 + children.reduce(0) { $0 + $1.nodes }
            } else {
                body = .value(value); bytes = (value as? String)?.utf8.count ?? 16; nodes = 1
            }
            guard bytes <= 4 * 1024 * 1024, nodes <= 120_000 else { throw AgentHookWireError.invalidMessage }
        }
        private init(body: Body, bytes: Int, nodes: Int) { self.body = body; self.bytes = bytes; self.nodes = nodes }

        var json: Any {
            switch body {
            case .object(let object): return object.mapValues(\.json)
            case .array(let array): return array.map(\.json)
            case .value(let value): return value
            case .opaque: return NSNull()
            }
        }
        func at(_ path: ArraySlice<Component>) -> Node? {
            guard let part = path.first else { return self }
            switch (body, part) {
            case (.object(let object), .key(let key)): return object[key]?.at(path.dropFirst())
            case (.array(let array), .index(let index)) where array.indices.contains(index): return array[index].at(path.dropFirst())
            default: return nil
            }
        }
        func opaqueAncestor(_ path: ArraySlice<Component>) -> Bool {
            guard let first = path.first else { return false }
            if case .opaque = body { return true }
            switch (body, first) {
            case (.object(let object), .key(let key)): return object[key]?.opaqueAncestor(path.dropFirst()) ?? false
            case (.array(let array), .index(let index)) where array.indices.contains(index): return array[index].opaqueAncestor(path.dropFirst())
            default: return false
            }
        }
        mutating func apply(_ path: ArraySlice<Component>, operation: String, value: Node?) throws {
            guard let part = path.first else {
                guard operation != "remove", let value else { throw AgentHookWireError.invalidMessage }
                self = value; return
            }
            // Output and historical bodies have intentionally been discarded.
            // Their parent positions remain exact; no descendant is projected.
            if case .opaque = body { return }
            let last = path.count == 1
            switch (body, part) {
            case (.object(var object), .key(let key)):
                let old = object[key]
                if last {
                    guard operation == "add" || old != nil else { throw AgentHookWireError.invalidMessage }
                    object[key] = operation == "remove" ? nil : value
                } else {
                    guard var child = old else { throw AgentHookWireError.invalidMessage }
                    try child.apply(path.dropFirst(), operation: operation, value: value); object[key] = child
                }
                let next = object[key]
                bytes += (next?.bytes ?? 0) - (old?.bytes ?? 0)
                    + (old == nil ? key.utf8.count + 16 : 0) - (next == nil ? key.utf8.count + 16 : 0)
                nodes += (next?.nodes ?? 0) - (old?.nodes ?? 0); body = .object(object)
            case (.array(var array), .index(let index)):
                guard index >= 0, index <= array.count else { throw AgentHookWireError.invalidMessage }
                if last, operation == "add", let value {
                    array.insert(value, at: index); bytes += value.bytes + 8; nodes += value.nodes
                } else {
                    guard array.indices.contains(index) else { throw AgentHookWireError.invalidMessage }
                    let old = array[index]
                    if last, operation == "remove" {
                        array.remove(at: index); bytes -= old.bytes + 8; nodes -= old.nodes
                    } else {
                        try array[index].apply(path.dropFirst(), operation: operation, value: value)
                        bytes += array[index].bytes - old.bytes; nodes += array[index].nodes - old.nodes
                    }
                }
                body = .array(array)
            default: throw AgentHookWireError.invalidMessage
            }
        }
    }

    private var root: Node
    private(set) var filteredNodeCount = 0
    var retainedBytes: Int { root.bytes }

    init(_ document: [String: Any]) throws {
        let prepared = try Self.recent(document)
        var budget = 120_000
        root = try Node(CodexDesktopProjection.filter(prepared, budget: &budget))
        filteredNodeCount = 120_000 - budget
        try trim()
    }

    /// Privacy-filter only new values and affected items, never the whole
    /// retained history. Commit remains transactional in the enclosing stream.
    mutating func apply(_ patches: [[String: Any]]) throws {
        filteredNodeCount = 0
        for patch in patches {
            guard let operation = patch["op"] as? String, ["add", "replace", "remove"].contains(operation),
                  let rawPath = patch["path"] as? [Any], rawPath.count <= 48,
                  operation == "remove" || patch["value"] != nil else { throw AgentHookWireError.invalidMessage }
            let path = try rawPath.map { part -> Component in
                if let key = part as? String { return .key(key) }
                guard let index = CodexDesktopProjection.integer(part), index >= 0, index <= Int64(Int.max) else { throw AgentHookWireError.invalidMessage }
                return .index(Int(index))
            }
            if path.isEmpty {
                guard operation != "remove", let document = patch["value"] as? [String: Any] else { throw AgentHookWireError.invalidMessage }
                self = try Self(document); continue
            }
            if root.opaqueAncestor(path[...]) { continue }
            var value: Node?
            if operation != "remove", let raw = patch["value"] {
                var prepared = raw
                if path == [.key("turns")], let turns = raw as? [Any] { prepared = Self.recentTail(turns) }
                if path == [.key("turnHistory")], let history = raw as? [String: Any] {
                    prepared = try Self.recentHistory(history, count: max(0, 2 - tailCount))
                }
                let context = itemContext(path)
                var budget = 120_000
                let normalized = path.map { part -> String in if case .key(let key) = part { return key }; return "[]" }
                let blocked = normalized.contains(where: CodexDesktopProjection.sensitive.contains)
                    || normalized.first.map { !CodexDesktopProjection.roots.contains($0) } == true
                let filtered = try CodexDesktopProjection.filter(prepared, path: normalized, item: context?.type,
                    publicText: context?.publicText ?? false, redacted: blocked, budget: &budget)
                filteredNodeCount += 120_000 - budget; value = try Node(filtered)
            }
            try root.apply(path[...], operation: operation, value: value)
            // Redact existing text immediately on a visibility change, before
            // any later array insertion/removal shifts this item's position.
            if let item = itemPath(path), path.count == item.count + 1,
               path.last == .key("type") || path.last == .key("phase"),
               let node = root.at(item[...]), case .object = node.body {
                var budget = 120_000
                let normalized = item.map { part -> String in if case .key(let key) = part { return key }; return "[]" }
                let value = try CodexDesktopProjection.filter(node.json, path: normalized, budget: &budget)
                filteredNodeCount += 120_000 - budget
                try root.apply(item[...], operation: "replace", value: Node(value))
            }
        }
        try trim()
    }

    var projection: [String: Any]? {
        guard case .object(let object) = root.body, let addresses = try? orderedTurns() else { return nil }
        var result = object.filter { $0.key != "turns" && $0.key != "turnHistory" }.mapValues(\.json)
        if let last = addresses.last {
            guard let turn = root.at(last[...]), case .object = turn.body else { return nil }
            result["turns"] = [turn.json]
        } else { result["turns"] = [[String: Any]]() }
        return result
    }

    private var tailCount: Int {
        guard let node = root.at([.key("turns")][...]), case .array(let turns) = node.body else { return 0 }
        return turns.count
    }
    private func orderedTurns() throws -> [[Component]] {
        guard let tail = root.at([.key("turns")][...]), case .array(let turns) = tail.body, turns.count <= 20_000 else { throw AgentHookWireError.invalidMessage }
        var addresses: [[Component]] = []
        if let history = root.at([.key("turnHistory")][...]), case .opaque = history.body {} else if root.at([.key("turnHistory")][...]) != nil {
            guard root.at([.key("turnHistory"), .key("kind")][...])?.json as? String == "canonical",
                  let islands = root.at([.key("turnHistory"), .key("history"), .key("islands")][...])?.json as? [[String: Any]],
                  let entities = root.at([.key("turnHistory"), .key("history"), .key("entitiesByKey")][...]),
                  case .object(let entries) = entities.body else { throw AgentHookWireError.invalidMessage }
            var seen: Set<String> = []
            for island in islands {
                guard let values = island["entries"] as? [[String: Any]] else { throw AgentHookWireError.invalidMessage }
                for value in values {
                    guard let key = value["value"] as? String, entries[key] != nil, seen.insert(key).inserted, addresses.count < 20_000 else { throw AgentHookWireError.invalidMessage }
                    addresses.append([.key("turnHistory"), .key("history"), .key("entitiesByKey"), .key(key)])
                }
            }
        }
        return addresses + turns.indices.map { [.key("turns"), .index($0)] }
    }
    private mutating func trim() throws {
        let ordered = try orderedTurns(), kept = Array(ordered.suffix(2))
        if let last = ordered.last, let node = root.at(last[...]), case .opaque = node.body { throw AgentHookWireError.invalidMessage }
        for path in ordered where !kept.contains(path) {
            if let node = root.at(path[...]), case .opaque = node.body { continue }
            try root.apply(path[...], operation: "replace", value: .opaque)
        }
        guard root.bytes <= 4 * 1024 * 1024, root.nodes <= 120_000 else { throw AgentHookWireError.invalidMessage }
    }
    private func itemPath(_ path: [Component]) -> [Component]? {
        for index in path.indices where index + 1 < path.count && path[index] == .key("items") {
            if case .index = path[index + 1] { return Array(path.prefix(index + 2)) }
        }
        return nil
    }
    private func itemContext(_ path: [Component]) -> (type: String?, publicText: Bool)? {
        guard let prefix = itemPath(path), let item = root.at(prefix[...])?.json as? [String: Any] else { return nil }
        let type = item["type"] as? String
        return (type, type == "userMessage" || type == "steeringUserMessage" || type == "agentMessage" && item["phase"] as? String == "commentary")
    }
    private static func recentTail(_ turns: [Any]) -> [Any] {
        turns.enumerated().map { $0.offset < turns.count - 2 ? NSNull() : $0.element }
    }
    private static func recent(_ document: [String: Any]) throws -> [String: Any] {
        guard let turns = document["turns"] as? [Any], turns.count <= 20_000 else { throw AgentHookWireError.invalidMessage }
        var document = document; document["turns"] = recentTail(turns)
        if let history = document["turnHistory"] as? [String: Any] {
            document["turnHistory"] = try recentHistory(history, count: max(0, 2 - turns.count))
        }
        return document
    }
    private static func recentHistory(_ value: [String: Any], count: Int) throws -> [String: Any] {
        guard value["kind"] as? String == "canonical", var history = value["history"] as? [String: Any],
              let entities = history["entitiesByKey"] as? [String: Any], let islands = history["islands"] as? [[String: Any]],
              entities.count <= 20_000 else { throw AgentHookWireError.invalidMessage }
        var keys: [String] = []
        for island in islands {
            guard let entries = island["entries"] as? [[String: Any]] else { throw AgentHookWireError.invalidMessage }
            for entry in entries {
                guard let key = entry["value"] as? String, keys.count < 20_000 else { throw AgentHookWireError.invalidMessage }
                keys.append(key)
            }
        }
        let kept = Set(keys.suffix(count))
        var pruned: [String: Any] = entities.mapValues { _ in NSNull() }
        for key in kept { if let value = entities[key] { pruned[key] = value } }
        history["entitiesByKey"] = pruned
        var result = value; result["history"] = history; return result
    }
}
