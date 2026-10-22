import Foundation
import XCTest
@testable import NotchX

final class NowPlayingLifecycleTests: XCTestCase {
    func testCancellationBeforeAndAfterEnqueueFinishesWithoutExecutingQueuedWork() async {
        let queue = DispatchQueue(label: "notchx.tests.script-queue")
        let blocked = DispatchSemaphore(value: 0)
        let started = expectation(description: "queue blocked")
        queue.async { started.fulfill(); blocked.wait() }
        defer { blocked.signal() }
        await fulfillment(of: [started], timeout: 2)

        let pending = NowPlayingScriptJob<Int>()
        let enqueued = expectation(description: "job enqueued")
        let waiter = Task {
            await withCheckedContinuation { continuation in
                pending.enqueue(on: queue, continuation: continuation) {
                    XCTFail("Cancelled queued work executed")
                    return 42
                }
                enqueued.fulfill()
            }
        }
        await fulfillment(of: [enqueued], timeout: 2)
        pending.cancel()
        pending.cancel()
        let cancelled = await waiter.value
        XCTAssertNil(cancelled)
        blocked.signal()
        queue.sync {}

        let cancelledBeforeEnqueue = NowPlayingScriptJob<Int>()
        cancelledBeforeEnqueue.cancel()
        let beforeValue = await withCheckedContinuation { continuation in
            cancelledBeforeEnqueue.enqueue(on: queue, continuation: continuation) {
                XCTFail("Previously cancelled work executed")
                return 42
            }
        }
        XCTAssertNil(beforeValue)
    }

    func testRunningCancellationDiscardsLateResultWhileNormalWorkCompletes() async {
        let queue = DispatchQueue(label: "notchx.tests.running-script")
        let running = NowPlayingScriptJob<Int>()
        let started = expectation(description: "script started")
        let finish = DispatchSemaphore(value: 0)
        defer { finish.signal() }
        let waiter = Task {
            await withCheckedContinuation { continuation in
                running.enqueue(on: queue, continuation: continuation) {
                    started.fulfill()
                    finish.wait()
                    return 42
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        running.cancel()
        let cancelled = await waiter.value
        XCTAssertNil(cancelled)
        finish.signal()
        queue.sync {}

        let normal = NowPlayingScriptJob<Int>()
        let value = await withCheckedContinuation { continuation in
            normal.enqueue(on: queue, continuation: continuation) { 42 }
        }
        XCTAssertEqual(value, 42)
    }

    func testClosedAdapterPipeDoesNotInstallAnotherReader() async {
        let pipe = JSONLinesPipeHandler()
        await pipe.close()
        await pipe.close()
        await pipe.readJSONLines(as: Int.self) { _ in
            XCTFail("Closed adapter pipe delivered data")
        }
    }
}
