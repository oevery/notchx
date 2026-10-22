import Foundation
import Darwin

enum AdapterProcessError: Error, Equatable {
    case timedOut, cancelled, outputTooLarge, failed(Int32)
}

/// Serializes output, cancellation and exit so every invocation completes once.
enum AdapterProcessRunner {
    /// Stop only this owned child. Keep its Process alive until escalation checks
    /// exit, so a stale saved PID can never target an unrelated process.
    static func stopOwnedProcess(_ process: Process) {
        process.terminationHandler = nil
        guard process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.2) {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
        }
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval = 5,
                    maximumOutputBytes: Int = 16 * 1024 * 1024) async throws -> Data {
        let invocation = AdapterProcessInvocation(maximumOutputBytes: maximumOutputBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                invocation.start(executable: executable, arguments: arguments, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            invocation.cancel()
        }
    }
}

private final class AdapterProcessInvocation: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.notchx.adapter-command")
    private let maximumOutputBytes: Int
    private let pipe = Pipe()
    private var process: Process?
    private var reader: DispatchSourceRead?
    private var continuation: CheckedContinuation<Data, Error>?
    private var output = Data()
    private var outputClosed = false
    private var failure: Error?
    private var finished = false
    private var cancelled = false
    private var deadline: DispatchWorkItem?
    private var escalation: DispatchWorkItem?

    init(maximumOutputBytes: Int) {
        self.maximumOutputBytes = max(0, maximumOutputBytes)
    }

    func start(executable: URL, arguments: [String], timeout: TimeInterval,
               continuation: CheckedContinuation<Data, Error>) {
        queue.async { [self] in
            self.continuation = continuation
            guard !cancelled else { finish(.failure(AdapterProcessError.cancelled)); return }
            do {
                let fd = pipe.fileHandleForReading.fileDescriptor
                guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) != -1 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [weak self] process in
                    guard let self else { return }
                    self.queue.async { self.completed(status: process.terminationStatus) }
                }
                self.process = process
                try process.run()
                try? pipe.fileHandleForWriting.close()
                let reader = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
                let readHandle = pipe.fileHandleForReading
                reader.setCancelHandler { try? readHandle.close() }
                reader.setEventHandler { [weak self] in self?.readOutput() }
                self.reader = reader
                reader.resume()
                let deadline = DispatchWorkItem { [weak self] in self?.stop(AdapterProcessError.timedOut) }
                self.deadline = deadline
                queue.asyncAfter(deadline: .now() + max(0, timeout), execute: deadline)
            } catch { finish(.failure(error)) }
        }
    }

    func cancel() {
        queue.async { [self] in
            cancelled = true
            if continuation != nil { stop(AdapterProcessError.cancelled) }
        }
    }

    private func readOutput() {
        guard !finished, failure == nil, !outputClosed else { return }
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        while failure == nil {
            let count = Darwin.read(pipe.fileHandleForReading.fileDescriptor, &bytes, bytes.count)
            if count > 0 {
                guard count <= maximumOutputBytes - output.count else {
                    stop(AdapterProcessError.outputTooLarge)
                    return
                }
                output.append(contentsOf: bytes.prefix(count))
            } else if count == 0 {
                outputClosed = true
                reader?.cancel()
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                stop(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                return
            }
        }
    }

    private func stop(_ error: Error) {
        guard !finished, failure == nil else { return }
        failure = error
        reader?.cancel()
        guard let process, process.isRunning else {
            finish(.failure(error))
            return
        }
        process.terminate()
        // Retain this exact Process until its exit is observed. Never signal a
        // saved PID after releasing the process that owns it.
        let escalation = DispatchWorkItem { [weak self, process] in
            guard let self, !self.finished, process.isRunning else { return }
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        self.escalation = escalation
        queue.asyncAfter(deadline: .now() + 0.2, execute: escalation)
    }

    private func completed(status: Int32) {
        guard !finished else { return }
        readOutput()
        if let failure { finish(.failure(failure)) }
        else if status != 0 { finish(.failure(AdapterProcessError.failed(status))) }
        else { finish(.success(output)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        escalation?.cancel()
        process?.terminationHandler = nil
        process = nil
        let readHandle = pipe.fileHandleForReading
        if let reader {
            reader.cancel()
            self.reader = nil
        } else { try? readHandle.close() }
        try? pipe.fileHandleForWriting.close()
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
