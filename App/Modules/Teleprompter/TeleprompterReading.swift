import Foundation

struct TeleprompterParagraph: Identifiable, Equatable {
    let id: Int
    let title: String
    static func parse(_ text: String) -> [Self] {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var offset = 0
        var result: [Self] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { result.append(Self(id: offset, title: String(trimmed.prefix(36)))) }
            offset += line.count + 1
        }
        return result
    }
}

struct TeleprompterSeekRequest: Equatable {
    let id = UUID()
    let displayOffset: Int
    var progress: Double? = nil
}

enum TeleprompterKeyboardAction: Equatable {
    case playPause, pause, faster, slower, nextParagraph, previousParagraph
    static func resolve(keyCode: UInt16, hasModifiers: Bool, isRepeat: Bool, isEditing: Bool) -> Self? {
        guard !hasModifiers, !isEditing else { return nil }
        switch keyCode {
        case 49: return isRepeat ? nil : .playPause
        case 53: return .pause
        case 24: return .faster
        case 27: return .slower
        case 125: return .nextParagraph
        case 126: return .previousParagraph
        default: return nil
        }
    }
}
