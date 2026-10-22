import Foundation
import Combine

struct TeleprompterReadingPosition: Codable, Equatable {
    let script: String
    let displayOffset: Int
    let progress: Double
}

/// Drafts never replace the applied script. Checkpoints never imply playback.
final class TeleprompterSessionStore: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private let preferences: UserDefaults
    private let draftKey = "teleprompter.draft"
    private let positionKey = "teleprompter.readingPosition"
    private let positionScriptKey = "teleprompter.readingPosition.script"
    private struct Checkpoint: Codable { let displayOffset: Int; let progress: Double }

    init(preferences: UserDefaults = .standard) { self.preferences = preferences }

    var draft: String? { preferences.string(forKey: draftKey) }
    func saveDraft(_ text: String) {
        objectWillChange.send()
        preferences.set(text, forKey: draftKey)
    }
    func discardDraft() {
        objectWillChange.send()
        preferences.removeObject(forKey: draftKey)
    }

    func position(for script: String) -> TeleprompterReadingPosition? {
        guard let data = preferences.data(forKey: positionKey),
              preferences.string(forKey: positionScriptKey) == script,
              let position = try? JSONDecoder().decode(Checkpoint.self, from: data),
              position.progress.isFinite,
              (0...1).contains(position.progress), position.displayOffset >= 0,
              position.displayOffset <= script.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").count,
              position.displayOffset > 0 || position.progress > 0 else { return nil }
        return TeleprompterReadingPosition(script: script, displayOffset: position.displayOffset, progress: position.progress)
    }

    func savePosition(_ position: TeleprompterReadingPosition) {
        let checkpoint = Checkpoint(displayOffset: position.displayOffset, progress: position.progress)
        guard position.progress.isFinite, let data = try? JSONEncoder().encode(checkpoint) else { return }
        if preferences.string(forKey: positionScriptKey) != position.script {
            preferences.set(position.script, forKey: positionScriptKey)
        }
        preferences.set(data, forKey: positionKey)
    }

    func clearPosition() {
        preferences.removeObject(forKey: positionKey)
        preferences.removeObject(forKey: positionScriptKey)
    }
}
