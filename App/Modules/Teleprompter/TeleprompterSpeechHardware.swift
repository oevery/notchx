import AVFoundation
import Speech

// Hardware boundaries only. Matching, retry generations and resource ownership
// remain in TeleprompterSpeechRecognizer and run unchanged in native tests.
protocol TeleprompterAudioInput: AnyObject {
    func outputFormat() -> AVAudioFormat
    func installTap(format: AVAudioFormat, receive: @escaping (AVAudioPCMBuffer) -> Void)
    func removeTap()
}
protocol TeleprompterAudioEngine: AnyObject {
    var input: any TeleprompterAudioInput { get }
    var isRunning: Bool { get }
    func prepare()
    func start() throws
    func stop()
}
protocol TeleprompterRecognitionRequest: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    func endAudio()
}
protocol TeleprompterRecognitionTask: AnyObject { func cancel() }
protocol TeleprompterSpeechService: AnyObject {
    var isAvailable: Bool { get }
    func makeRequest(contextualStrings: [String]) -> any TeleprompterRecognitionRequest
    func recognize(_ request: any TeleprompterRecognitionRequest,
                   receive: @escaping (String?, Error?) -> Void) -> any TeleprompterRecognitionTask
}

extension SFSpeechAudioBufferRecognitionRequest: TeleprompterRecognitionRequest {}
extension SFSpeechRecognitionTask: TeleprompterRecognitionTask {}

final class SystemTeleprompterAudioInput: TeleprompterAudioInput {
    private let node: AVAudioInputNode
    init(_ node: AVAudioInputNode) { self.node = node }
    func outputFormat() -> AVAudioFormat { node.outputFormat(forBus: 0) }
    func installTap(format: AVAudioFormat, receive: @escaping (AVAudioPCMBuffer) -> Void) {
        node.installTap(onBus: 0, bufferSize: 512, format: format) { buffer, _ in receive(buffer) }
    }
    func removeTap() { node.removeTap(onBus: 0) }
}

final class SystemTeleprompterAudioEngine: TeleprompterAudioEngine {
    private let engine = AVAudioEngine()
    var input: any TeleprompterAudioInput { SystemTeleprompterAudioInput(engine.inputNode) }
    var isRunning: Bool { engine.isRunning }
    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }
}

final class SystemTeleprompterSpeechService: TeleprompterSpeechService {
    private let recognizer: SFSpeechRecognizer
    init?(locale: String) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else { return nil }
        self.recognizer = recognizer
    }
    var isAvailable: Bool { recognizer.isAvailable }
    func makeRequest(contextualStrings: [String]) -> any TeleprompterRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = contextualStrings
        return request
    }
    func recognize(_ request: any TeleprompterRecognitionRequest,
                   receive: @escaping (String?, Error?) -> Void) -> any TeleprompterRecognitionTask {
        // Only makeRequest creates requests for this concrete service.
        precondition(request is SFSpeechAudioBufferRecognitionRequest)
        return recognizer.recognitionTask(with: request as! SFSpeechAudioBufferRecognitionRequest) {
            receive($0?.bestTranscription.formattedString, $1)
        }
    }
}
