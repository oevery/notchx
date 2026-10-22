#!/usr/bin/env python3
"""Execute the production speech recognizer against instrumented audio doubles.

This checks lifecycle control flow, not AVFoundation/Speech hardware integration.
Native SDK compilation and real microphone validation still require macOS.
"""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
recognizer = (ROOT / 'App/Modules/Teleprompter/TeleprompterSpeechRecognizer.swift').read_text()
recognizer = '\n'.join(line for line in recognizer.splitlines() if not line.startswith('import '))
stubs = r'''
import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
enum L10n {
    static func text(_ value: String) -> String { value }
    static func format(_ value: String, _ argument: String) -> String { value + argument }
}
final class PermissionsManager {
    static let shared = PermissionsManager()
    var microphone = true
    var speech = true
    func checkMicrophone() -> Bool { microphone }
    func checkSpeechRecognition() -> Bool { speech }
    func requestTeleprompterWordTrackingAccess() {}
}
enum TeleprompterTextTokenizer {
    struct SpeechMatchingText {
        let text: String
        var displayOffsetBySpeechOffset: [Int] { Array(0...text.count) }
        static let empty = SpeechMatchingText(text: "")
        func displayOffset(forSpeechOffset offset: Int) -> Int { offset }
    }
    static func speechMatchingText(from text: String) -> SpeechMatchingText { .init(text: text) }
    static func displayText(from text: String) -> String { text }
}
final class AVAudioFormat {
    var sampleRate: Double { AVAudioEngine.validFormat ? 48000 : 0 }
    let channelCount = 1
}
final class AVAudioPCMBuffer {
    let floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? = nil
    let frameLength = 0
}
final class AVAudioInputNode {
    var installed = false
    var removals = 0
    func outputFormat(forBus bus: Int) -> AVAudioFormat { AVAudioFormat() }
    func installTap(onBus bus: Int, bufferSize: Int, format: AVAudioFormat,
                    block: @escaping (AVAudioPCMBuffer, Int) -> Void) {
        precondition(!installed, "Duplicate tap")
        installed = true
    }
    func removeTap(onBus bus: Int) {
        precondition(installed, "Removed a tap that was never installed")
        installed = false
        removals += 1
    }
}
final class AVAudioEngine {
    static var engines: [AVAudioEngine] = []
    static var inputReads = 0
    static var validFormat = true
    static var failStart = false
    enum Failure: Error { case start }
    let node = AVAudioInputNode()
    var inputNode: AVAudioInputNode { Self.inputReads += 1; return node }
    var isRunning = false
    var stops = 0
    init() { Self.engines.append(self) }
    func prepare() {}
    func start() throws {
        if Self.failStart { throw Failure.start }
        isRunning = true
    }
    func stop() { precondition(isRunning); isRunning = false; stops += 1 }
}
final class SFSpeechAudioBufferRecognitionRequest {
    enum TaskHint { case dictation }
    var shouldReportPartialResults = false
    var taskHint = TaskHint.dictation
    var addsPunctuation = false
    var contextualStrings: [String] = []
    var endings = 0
    init() { SFSpeechRecognizer.requests.append(self) }
    func append(_ buffer: AVAudioPCMBuffer) {}
    func endAudio() { endings += 1 }
}
final class SFSpeechRecognitionTask {
    var cancellations = 0
    func cancel() { cancellations += 1 }
}
struct Transcription { let formattedString: String }
struct SpeechResult { let bestTranscription: Transcription }
final class SFSpeechRecognizer {
    static var available = true
    static var requests: [SFSpeechAudioBufferRecognitionRequest] = []
    static var tasks: [SFSpeechRecognitionTask] = []
    static var handlers: [(SpeechResult?, Error?) -> Void] = []
    var isAvailable: Bool { Self.available }
    init?(locale: Locale) {}
    func recognitionTask(with request: SFSpeechAudioBufferRecognitionRequest,
                         resultHandler: @escaping (SpeechResult?, Error?) -> Void) -> SFSpeechRecognitionTask {
        let task = SFSpeechRecognitionTask()
        Self.tasks.append(task)
        Self.handlers.append(resultHandler)
        return task
    }
}
'''
checks = r'''
@main struct AudioLifecycleChecks {
    static func main() {
        let recognizer = TeleprompterSpeechRecognizer()
        recognizer.stop()
        recognizer.stop()
        recognizer.reset()
        recognizer.start(with: "", localeIdentifier: "en-US")
        PermissionsManager.shared.microphone = false
        recognizer.start(with: "Script", localeIdentifier: "en-US")
        PermissionsManager.shared.microphone = true
        PermissionsManager.shared.speech = false
        recognizer.start(with: "Script", localeIdentifier: "en-US")
        PermissionsManager.shared.speech = true
        SFSpeechRecognizer.available = false
        recognizer.start(with: "Script", localeIdentifier: "en-US")
        recognizer.stop()
        precondition(AVAudioEngine.engines.isEmpty, "Idle/denied/unavailable paths created audio hardware")
        precondition(AVAudioEngine.inputReads == 0, "Idle cleanup accessed input hardware")

        SFSpeechRecognizer.available = true
        recognizer.start(with: "Script", localeIdentifier: "en-US")
        precondition(recognizer.isListening && AVAudioEngine.inputReads == 1)
        let first = AVAudioEngine.engines.last!
        let firstRequest = SFSpeechRecognizer.requests.last!
        let firstTask = SFSpeechRecognizer.tasks.last!
        recognizer.stop()
        recognizer.stop()
        recognizer.reset()
        precondition(!recognizer.isListening && !first.isRunning)
        precondition(first.stops == 1 && first.node.removals == 1)
        precondition(firstRequest.endings == 1 && firstTask.cancellations == 1)
        precondition(AVAudioEngine.inputReads == 1, "Stop rediscovered inputNode")

        // Starting again while active cleans only the old installed tap.
        recognizer.start(with: "Script", localeIdentifier: "en-US")
        let second = AVAudioEngine.engines.last!
        recognizer.start(with: "New script", localeIdentifier: "en-US")
        let third = AVAudioEngine.engines.last!
        precondition(second !== third && second.stops == 1 && second.node.removals == 1)
        precondition(third.isRunning && third.node.installed)
        recognizer.stop()
        precondition(third.stops == 1 && third.node.removals == 1)
        precondition(AVAudioEngine.inputReads == 3)

        // Failed hardware discovery never installed a tap; stop cancels its retry.
        AVAudioEngine.validFormat = false
        recognizer.start(with: "Script", localeIdentifier: "en-US")
        let invalid = AVAudioEngine.engines.last!
        recognizer.stop()
        recognizer.stop()
        precondition(invalid.stops == 0 && invalid.node.removals == 0)
        let enginesBeforeRetry = AVAudioEngine.engines.count
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        precondition(AVAudioEngine.engines.count == enginesBeforeRetry, "Stopped recognition restarted")
        precondition(AVAudioEngine.inputReads == 4)

        // A start failure still removes the installed tap exactly once.
        AVAudioEngine.validFormat = true
        AVAudioEngine.failStart = true
        recognizer.start(with: "Script", localeIdentifier: "en-US")
        let failed = AVAudioEngine.engines.last!
        recognizer.stop()
        precondition(!recognizer.isListening && failed.node.removals == 1 && failed.stops == 0)
        precondition(AVAudioEngine.inputReads == 5)
        AVAudioEngine.failStart = false
        let script = "one two three four five six seven eight nine ten"
        recognizer.start(with: script, localeIdentifier: "en-US")
        let handler = SFSpeechRecognizer.handlers.last!
        handler(SpeechResult(bestTranscription: Transcription(formattedString: "one two three")), nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        let progress = recognizer.recognizedCharCount
        precondition(progress > 0, "Fixture did not advance script")
        recognizer.stop()
        recognizer.start(with: script, localeIdentifier: "en-US", resuming: true)
        precondition(recognizer.recognizedCharCount == progress, "Resume discarded script position")
        handler(SpeechResult(bestTranscription: Transcription(formattedString: script)), nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(recognizer.recognizedCharCount == progress, "Stale transcript advanced resumed session")
        recognizer.stop()
        recognizer.start(with: script, localeIdentifier: "zh-CN", resuming: true)
        precondition(recognizer.recognizedCharCount == 0, "Language change retained stale recognition")
        recognizer.stop()
        var terminalFailures = 0
        recognizer.onTerminalFailure = { terminalFailures += 1 }
        SFSpeechRecognizer.available = false
        recognizer.start(with: script, localeIdentifier: "en-US")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(terminalFailures == 1, "Terminal recognition failure did not notify the host")
        let inputReadsBeforeSeek = AVAudioEngine.inputReads
        recognizer.preparePosition(in: script, localeIdentifier: "en-US", displayOffset: 14)
        precondition(recognizer.recognizedCharCount == 14 && !recognizer.isListening)
        precondition(AVAudioEngine.inputReads == inputReadsBeforeSeek, "Seeking initialized audio hardware")
        SFSpeechRecognizer.available = true
        recognizer.start(with: script, localeIdentifier: "en-US", resuming: true)
        precondition(recognizer.recognizedCharCount == 14, "Resuming lost selected paragraph")
        recognizer.stop()
        precondition(SFSpeechRecognizer.requests.allSatisfy { $0.endings == 1 })
        precondition(SFSpeechRecognizer.tasks.allSatisfy { $0.cancellations == 1 })
        print("PASS: production speech stop-before-start, repeated stop/reset, permission/availability gates, installed tap cleanup, restart replacement, canceled retry and start failure; cleanup never reads inputNode")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='notchx-speech-lifecycle-') as directory:
    source = Path(directory) / 'AudioLifecycleChecks.swift'
    binary = Path(directory) / 'AudioLifecycleChecks'
    source.write_text(stubs + recognizer + checks)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), '-module-cache-path', str(Path(directory) / 'module-cache'), '-swift-version', '5', '-parse-as-library', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
