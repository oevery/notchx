import XCTest
@testable import NotchX

@MainActor
final class PlaybackFavoriteTests: XCTestCase {
    func testOnlyKnownMenuActionsDescribeFavoriteState() {
        XCTAssertEqual(NetEaseFavoriteAccess.state(for: "喜欢歌曲"), false)
        XCTAssertEqual(NetEaseFavoriteAccess.state(for: "取消喜欢"), true)
        XCTAssertNil(NetEaseFavoriteAccess.state(for: "收藏歌单"))
        XCTAssertNil(NetEaseFavoriteAccess.state(for: ""))
    }

    func testWriteMustBeConfirmedAndDuplicateClickIsIgnored() async {
        let access = FakeFavoriteAccess()
        let controller = PlaybackFavoriteController(access: access)
        controller.reset(context: "song-a")
        await controller.refresh()
        XCTAssertEqual(controller.state, false)
        await access.holdWrites()
        controller.toggle(context: "song-a")
        await waitUntil { await access.hasHeldWrite() }
        controller.toggle(context: "song-a")
        XCTAssertEqual(controller.state, false, "Do not optimistically fill the heart")
        XCTAssertTrue(controller.isPending)
        await access.releaseWrite()
        await waitUntil { !controller.isPending }
        XCTAssertEqual(controller.state, true)
        let writes = await access.writeCount()
        XCTAssertEqual(writes, 1)
        controller.toggle(context: "song-a")
        await waitUntil { !controller.isPending }
        XCTAssertEqual(controller.state, false)
    }

    func testChangingTrackDiscardsLateReadAndCannotWriteOldTrack() async {
        let access = FakeFavoriteAccess()
        let controller = PlaybackFavoriteController(access: access)
        controller.reset(context: "song-a")
        await access.holdReads()
        let refresh = Task { await controller.refresh() }
        await waitUntil { await access.hasHeldRead() }
        controller.reset(context: "song-b")
        await access.releaseRead()
        await refresh.value
        XCTAssertNil(controller.state)
        controller.toggle(context: "song-a")
        let writes = await access.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testTransportCancellationKeepsConfirmedHeartAndDiscardsPendingWrite() async {
        let access = FakeFavoriteAccess()
        let controller = PlaybackFavoriteController(access: access)
        controller.reset(context: "song-a")
        await controller.refresh()
        await access.holdWrites()
        controller.toggle(context: "song-a")
        await waitUntil { await access.hasHeldWrite() }
        controller.cancelOperation()
        await access.releaseWrite()
        await Task.yield()
        XCTAssertEqual(controller.context, "song-a")
        XCTAssertEqual(controller.state, false)
        XCTAssertFalse(controller.isPending)
    }

    func testUnavailableReadPreventsFavoriteWrite() async {
        let access = FakeFavoriteAccess()
        await access.makeUnavailable()
        let controller = PlaybackFavoriteController(access: access)
        controller.reset(context: "song-a")
        await controller.refresh()
        controller.toggle(context: "song-a")
        XCTAssertNil(controller.state)
        XCTAssertFalse(controller.isPending)
        let writes = await access.writeCount()
        XCTAssertEqual(writes, 0)
    }

    func testPermissionDenialIsExplainedAndGrantRecoversWithoutReopeningPage() async {
        let access = FakeFavoriteAccess()
        await access.setAuthorized(false)
        let controller = PlaybackFavoriteController(access: access)
        controller.reset(context: "song-a")
        await controller.refresh()
        XCTAssertTrue(controller.needsPermission)
        XCTAssertNil(controller.state)
        controller.toggle(context: "song-a")
        let writes = await access.writeCount()
        XCTAssertEqual(writes, 0)
        await access.setAuthorized(true)
        await controller.refresh()
        XCTAssertFalse(controller.needsPermission)
        XCTAssertEqual(controller.state, false)
    }

    func testClosingPageDiscardsLateWriteConfirmation() async {
        let access = FakeFavoriteAccess()
        let controller = PlaybackFavoriteController(access: access)
        controller.reset(context: "song-a")
        await controller.refresh()
        await access.holdWrites()
        controller.toggle(context: "song-a")
        await waitUntil { await access.hasHeldWrite() }
        controller.reset(context: nil)
        await access.releaseWrite()
        await Task.yield()
        XCTAssertNil(controller.state)
        XCTAssertFalse(controller.isPending)
        XCTAssertFalse(controller.error)
    }

    func testFailedOrUnconfirmedWriteDoesNotReportSuccessAndCanRecover() async {
        for sent in [false, true] {
            let access = FakeFavoriteAccess()
            await access.failWrite(sent: sent)
            let controller = PlaybackFavoriteController(access: access)
            controller.reset(context: "song-a")
            await controller.refresh()
            controller.toggle(context: "song-a")
            await waitUntil { !controller.isPending }
            XCTAssertNil(controller.state)
            XCTAssertTrue(controller.error)
            await controller.refresh()
            XCTAssertEqual(controller.state, false)
            XCTAssertFalse(controller.error)
        }
    }

    private func waitUntil(_ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(4)
        while !(await condition()) {
            if Date() > deadline { XCTFail("Timed out waiting for favorite operation"); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private actor FakeFavoriteAccess: FavoriteAccess {
    private var authorized = true
    func setAuthorized(_ value: Bool) { authorized = value }
    func isAuthorized() async -> Bool { authorized }
    private var favorite = false
    private var writes = 0
    private var holdRead = false
    private var holdWrite = false
    private var readWaiter: CheckedContinuation<Void, Never>?
    private var writeWaiter: CheckedContinuation<Void, Never>?
    private var sendResult = true
    private var updateOnWrite = true
    private var available = true
    func makeUnavailable() { available = false }

    func holdReads() { holdRead = true }
    func holdWrites() { holdWrite = true }
    func hasHeldRead() -> Bool { readWaiter != nil }
    func hasHeldWrite() -> Bool { writeWaiter != nil }
    func releaseRead() { holdRead = false; readWaiter?.resume(); readWaiter = nil }
    func releaseWrite() { holdWrite = false; writeWaiter?.resume(); writeWaiter = nil }
    func writeCount() -> Int { writes }
    func failWrite(sent: Bool) { sendResult = sent; updateOnWrite = false }

    func read() async -> Bool? {
        guard available else { return nil }
        let captured = favorite
        if holdRead { await withCheckedContinuation { readWaiter = $0 } }
        return captured
    }

    func toggle(expected: Bool) async -> Bool {
        writes += 1
        if holdWrite { await withCheckedContinuation { writeWaiter = $0 } }
        guard !Task.isCancelled, favorite == expected else { return false }
        if updateOnWrite { favorite.toggle() }
        return sendResult
    }
}
