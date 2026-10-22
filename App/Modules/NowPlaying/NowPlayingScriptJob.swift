import Foundation

// NSAppleScript itself cannot be interrupted safely. Cancel queued scripts and resume
// their waiters immediately; results from an already running script are discarded.
final class NowPlayingScriptJob<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var isCancelled = false
    private var continuation: CheckedContinuation<Value?, Never>?
    private var workItem: DispatchWorkItem?

    func enqueue(on queue: DispatchQueue, continuation: CheckedContinuation<Value?, Never>, work: @escaping () -> Value?) {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        let item = DispatchWorkItem { [self] in
            lock.lock()
            let shouldRun = !isCancelled
            lock.unlock()
            guard shouldRun else { return }
            finish(with: work())
        }
        workItem = item
        lock.unlock()
        queue.async(execute: item)
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let item = workItem
        workItem = nil
        let pending = continuation
        continuation = nil
        lock.unlock()
        item?.cancel()
        pending?.resume(returning: nil)
    }

    private func finish(with value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        workItem = nil
        let result = isCancelled ? nil : value
        lock.unlock()
        pending?.resume(returning: result)
    }
}
