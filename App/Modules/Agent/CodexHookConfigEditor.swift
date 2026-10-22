import Foundation

/// A deliberately narrow editor for sections emitted by Codex's TOML writer.
/// It never rewrites the document or trust fields. Unsupported syntax is an
/// explicit failure; strings containing apparent headers are not sections.
enum CodexHookConfigEditor {
    static func settingEnablement(_ values: [String: Bool], in bytes: Data) throws -> Data {
        guard var text = String(data: bytes, encoding: .utf8), !text.contains("\r") else {
            throw CodexHookConfigurationError.invalidConfiguration
        }
        var lines = text.components(separatedBy: "\n")
        var section: String?, found: Set<String> = [], multiline: String?
        let headers = Dictionary(uniqueKeysWithValues: try values.keys.map { key in
            ("[hooks.state.\(try quoted(key))]", key)
        })
        for index in lines.indices {
            let original = lines[index]
            let trimmed = original.trimmingCharacters(in: .whitespaces)
            let wasMultiline = multiline != nil
            try scanStrings(original, multiline: &multiline)
            if wasMultiline { continue }
            if trimmed.hasPrefix("[") {
                section = headers[trimmed]
                continue
            }
            guard let key = section, let enabled = values[key],
                  trimmed.range(of: #"^enabled\s*="#, options: .regularExpression) != nil else { continue }
            guard !found.contains(key),
                  let range = original.range(of: #"^(\s*enabled\s*=\s*)(true|false)(\s*(#.*)?)$"#, options: .regularExpression),
                  range == original.startIndex..<original.endIndex else { throw CodexHookConfigurationError.invalidConfiguration }
            let expression = try NSRegularExpression(pattern: #"^(\s*enabled\s*=\s*)(true|false)(\s*(#.*)?)$"#)
            lines[index] = expression.stringByReplacingMatches(in: original, range: NSRange(original.startIndex..., in: original),
                withTemplate: "$1" + (enabled ? "true" : "false") + "$3")
            found.insert(key)
        }
        guard multiline == nil, found == Set(values.keys) else { throw CodexHookConfigurationError.invalidConfiguration }
        text = lines.joined(separator: "\n")
        return Data(text.utf8)
    }

    private static func quoted(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard !value.contains("\n"), !value.contains("\r"), !value.utf8.contains(0),
              let text = String(data: try encoder.encode(value), encoding: .utf8) else {
            throw CodexHookConfigurationError.invalidConfiguration
        }
        return text
    }

    private static func scanStrings(_ line: String, multiline: inout String?) throws {
        let chars = Array(line), double: [Character] = ["\"", "\"", "\""], single: [Character] = ["'", "'", "'"]
        var index = 0, quote: Character?
        while index < chars.count {
            let character = chars[index]
            if let kind = multiline {
                let delimiter = kind == "double" ? double : single
                if character == "\\", kind == "double" { index += 2; continue }
                if index + 3 <= chars.count, Array(chars[index..<index + 3]) == delimiter { multiline = nil; index += 3; continue }
                index += 1; continue
            }
            if let current = quote {
                if current == "\"", character == "\\" { index += 2; continue }
                if character == current { quote = nil }
                index += 1; continue
            }
            if character == "#" { break }
            if character == "\"" || character == "'" {
                let delimiter = character == "\"" ? double : single
                if index + 3 <= chars.count, Array(chars[index..<index + 3]) == delimiter {
                    multiline = character == "\"" ? "double" : "single"; index += 3; continue
                }
                quote = character
            }
            index += 1
        }
        guard quote == nil else { throw CodexHookConfigurationError.invalidConfiguration }
    }
}
