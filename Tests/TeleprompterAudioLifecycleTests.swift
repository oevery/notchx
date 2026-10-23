import AVFoundation
import XCTest
@testable import NotchX

private final class AudioInputProbe: TeleprompterAudioInput {
    var valid = true, installed = false
    var removals = 0
    func outputFormat() -> AVAudioFormat {
        valid ? AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)! : AVAudioFormat()
    }
    func installTap(format: AVAudioFormat, receive: @escaping (AVAudioPCMBuffer) -> Void) {
        XCTAssertFalse(installed)
        installed = true
    }
    func removeTap() { XCTAssertTrue(installed); installed = false; removals += 1 }
}
private final class AudioEngineProbe: TeleprompterAudioEngine {
    let node = AudioInputProbe()
    var reads = 0, stops = 0
    var isRunning = false, failStart = false
    var input: any TeleprompterAudioInput { reads += 1; return node }
    func prepare() {}
    func start() throws {
        if failStart { throw NSError(domain: "audio fixture", code: 1) }
        isRunning = true
    }
    func stop() { XCTAssertTrue(isRunning); isRunning = false; stops += 1 }
}
private final class SpeechRequestProbe: TeleprompterRecognitionRequest {
    var endings = 0
    func append(_ buffer: AVAudioPCMBuffer) {}
    func endAudio() { endings += 1 }
}
private final class SpeechTaskProbe: TeleprompterRecognitionTask {
    var cancellations = 0
    func cancel() { cancellations += 1 }
}
private final class SpeechServiceProbe: TeleprompterSpeechService {
    var isAvailable = true
    var requests: [SpeechRequestProbe] = []
    var tasks: [SpeechTaskProbe] = []
    var handlers: [(String?, Error?) -> Void] = []
    func makeRequest(contextualStrings: [String]) -> any TeleprompterRecognitionRequest {
        let request = SpeechRequestProbe(); requests.append(request); return request
    }
    func recognize(_ request: any TeleprompterRecognitionRequest,
                   receive: @escaping (String?, Error?) -> Void) -> any TeleprompterRecognitionTask {
        let task = SpeechTaskProbe(); tasks.append(task); handlers.append(receive); return task
    }
}
private final class SpeechHardwareProbe {
    var microphone = true, speech = true, validFormat = true, failStart = false
    var permissionRequests = 0
    let service = SpeechServiceProbe()
    var engines: [AudioEngineProbe] = []
    func recognizer() -> TeleprompterSpeechRecognizer {
        TeleprompterSpeechRecognizer(microphoneAccess: { self.microphone }, speechAccess: { self.speech },
            requestAccess: { self.permissionRequests += 1 }, makeEngine: {
                let engine = AudioEngineProbe()
                engine.node.valid = self.validFormat
                engine.failStart = self.failStart
                self.engines.append(engine)
                return engine
            }, makeRecognizer: { _ in self.service })
    }
    func assertReleased(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(engines.allSatisfy { !$0.isRunning && !$0.node.installed }, file: file, line: line)
        XCTAssertTrue(service.requests.allSatisfy { $0.endings == 1 }, file: file, line: line)
        XCTAssertTrue(service.tasks.allSatisfy { $0.cancellations == 1 }, file: file, line: line)
    }
}

@MainActor
final class TeleprompterAudioLifecycleTests: XCTestCase {
    private let script = "one two three four five six seven eight nine ten"
    private func drainCallbacks() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    func testIdleDeniedAndUnavailablePathsNeverCreateAudioHardware() {
        let hardware = SpeechHardwareProbe(), recognizer: TeleprompterSpeechRecognizer
        recognizer = hardware.recognizer()
        recognizer.stop(); recognizer.stop(); recognizer.reset()
        recognizer.start(with: "", localeIdentifier: "en-US")
        hardware.microphone = false
        recognizer.start(with: script, localeIdentifier: "en-US")
        hardware.microphone = true; hardware.speech = false
        recognizer.start(with: script, localeIdentifier: "en-US")
        XCTAssertEqual(hardware.permissionRequests, 2)
        hardware.speech = true; hardware.service.isAvailable = false
        recognizer.start(with: script, localeIdentifier: "en-US")
        recognizer.stop()
        XCTAssertTrue(hardware.engines.isEmpty)
        XCTAssertFalse(recognizer.isListening)
    }
    func testRepeatedStopAndActiveReplacementReleaseEachResourceExactlyOnce() {
        let hardware = SpeechHardwareProbe()
        let recognizer = hardware.recognizer()
        recognizer.start(with: script, localeIdentifier: "en-US")
        XCTAssertTrue(recognizer.isListening)
        recognizer.stop(); recognizer.stop(); recognizer.reset()
        recognizer.start(with: script, localeIdentifier: "en-US")
        recognizer.start(with: "Replacement", localeIdentifier: "en-US")
        XCTAssertTrue(hardware.engines[2].isRunning)
        XCTAssertFalse(hardware.engines[1].isRunning)
        recognizer.stop()
        XCTAssertEqual(hardware.engines.count, 3)
        for engine in hardware.engines {
            XCTAssertEqual(engine.reads, 1, "Cleanup must not rediscover input hardware")
            XCTAssertEqual(engine.stops, 1)
            XCTAssertEqual(engine.node.removals, 1)
        }
        hardware.assertReleased()
    }
    func testInvalidFormatRetryIsCancelledAndStartFailureRemovesOnlyInstalledTap() async throws {
        let hardware = SpeechHardwareProbe()
        let recognizer = hardware.recognizer()
        hardware.validFormat = false
        recognizer.start(with: script, localeIdentifier: "en-US")
        recognizer.stop(); recognizer.stop()
        // Wait past the production 0.5s retry deadline to prove cancellation.
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertEqual(hardware.engines.count, 1)
        XCTAssertEqual(hardware.engines[0].node.removals, 0)
        XCTAssertEqual(hardware.engines[0].stops, 0)
        hardware.validFormat = true; hardware.failStart = true
        recognizer.start(with: script, localeIdentifier: "en-US")
        recognizer.stop()
        XCTAssertFalse(recognizer.isListening)
        XCTAssertEqual(hardware.engines[1].node.removals, 1)
        XCTAssertEqual(hardware.engines[1].stops, 0)
        hardware.assertReleased()
    }
    func testResumeRejectsOldTranscriptsAndLanguageChangeResetsProgress() async throws {
        let hardware = SpeechHardwareProbe()
        let recognizer = hardware.recognizer()
        defer { recognizer.stop() }
        recognizer.start(with: script, localeIdentifier: "en-US")
        let oldHandler = try XCTUnwrap(hardware.service.handlers.last)
        oldHandler("one two three", nil)
        await drainCallbacks()
        let progress = recognizer.recognizedCharCount
        XCTAssertGreaterThan(progress, 0)
        recognizer.stop()
        recognizer.start(with: script, localeIdentifier: "en-US", resuming: true)
        XCTAssertEqual(recognizer.recognizedCharCount, progress)
        oldHandler(script, nil)
        await drainCallbacks()
        XCTAssertEqual(recognizer.recognizedCharCount, progress)
        recognizer.stop()
        recognizer.start(with: script, localeIdentifier: "zh-CN", resuming: true)
        XCTAssertEqual(recognizer.recognizedCharCount, 0)
        recognizer.stop()
        hardware.assertReleased()
    }
    func testTerminalFailureNotifiesHostAndSeekingDoesNotInitializeHardware() async {
        let hardware = SpeechHardwareProbe()
        let recognizer = hardware.recognizer()
        var failures = 0
        recognizer.onTerminalFailure = { failures += 1 }
        hardware.service.isAvailable = false
        recognizer.start(with: script, localeIdentifier: "en-US")
        await drainCallbacks()
        XCTAssertEqual(failures, 1)
        recognizer.preparePosition(in: script, localeIdentifier: "en-US", displayOffset: 14)
        XCTAssertEqual(recognizer.recognizedCharCount, 14)
        XCTAssertFalse(recognizer.isListening)
        XCTAssertTrue(hardware.engines.isEmpty)
        hardware.service.isAvailable = true
        recognizer.start(with: script, localeIdentifier: "en-US", resuming: true)
        XCTAssertEqual(recognizer.recognizedCharCount, 14)
        recognizer.stop()
        hardware.assertReleased()
    }
}
