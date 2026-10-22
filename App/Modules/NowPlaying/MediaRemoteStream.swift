import Foundation

/// Frame bytes before decoding: pipe reads can split a UTF-8 scalar anywhere.
struct MediaRemoteLineBuffer {
    enum Failure: Error { case lineTooLong }
    let maximumLineBytes: Int
    private var pending = Data()

    init(maximumLineBytes: Int = 16 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ chunk: Data) throws -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let end = chunk[start...].firstIndex(of: 0x0A) ?? chunk.endIndex
            guard end - start <= maximumLineBytes - pending.count else {
                pending.removeAll()
                throw Failure.lineTooLong
            }
            pending.append(contentsOf: chunk[start..<end])
            if end == chunk.endIndex { break }
            if !pending.isEmpty { lines.append(pending) }
            pending = Data()
            start = chunk.index(after: end)
        }
        return lines
    }
}

actor JSONLinesPipeHandler {
    private let pipe = Pipe()
    private lazy var fileHandle = pipe.fileHandleForReading
    private var lines = MediaRemoteLineBuffer()
    private var pendingRead: CheckedContinuation<Data, Error>?
    private var isClosed = false

    func getPipe() -> Pipe {
        pipe
    }

    func readJSONLines<T: Decodable>(as type: T.Type, onLine: @escaping (T) async -> Void) async {
        do {
            while !Task.isCancelled, !isClosed {
                let data = try await readData()
                guard !data.isEmpty else { break }

                for line in try lines.append(data) {
                    guard !Task.isCancelled, !isClosed else { return }
                    guard let decoded = try? JSONDecoder().decode(T.self, from: line) else { continue }
                    await onLine(decoded)
                }
            }
        } catch {
            print("[NowPlaying] Error reading MediaRemote adapter stream: \(error)")
        }
    }

    private func readData() async throws -> Data {
        guard !isClosed, !Task.isCancelled else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingRead = continuation
            fileHandle.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                handle.readabilityHandler = nil
                Task { await self?.finishRead(data) }
            }
        }
    }

    private func finishRead(_ data: Data) {
        let continuation = pendingRead
        pendingRead = nil
        continuation?.resume(returning: data)
    }

    func close() async {
        guard !isClosed else { return }
        isClosed = true
        lines = MediaRemoteLineBuffer()
        finishRead(Data())
        do {
            fileHandle.readabilityHandler = nil
            try fileHandle.close()
            try pipe.fileHandleForWriting.close()
        } catch {
            print("[NowPlaying] Error closing MediaRemote adapter pipe: \(error)")
        }
    }
}
