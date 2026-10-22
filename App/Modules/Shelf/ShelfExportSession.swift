import AppKit
import Foundation

/// One lifecycle for prepared, delivered and cancelled file exports. Only
/// unpublished copies are deleted immediately; consumers keep delivered copies.
final class ShelfExportSession: @unchecked Sendable {
    private struct Copy {
        let url: URL
        let lease: ShelfExportLease
        var delivered = false
    }
    private let cache: ShelfExportCache
    private let lock = NSLock()
    private var copies: [Copy] = []
    private var finished = false

    init(cache: ShelfExportCache) { self.cache = cache }

    func copy(_ source: URL) throws -> URL {
        lock.lock()
        let canStart = !finished
        lock.unlock()
        guard canStart else { throw CocoaError(.userCancelled) }
        let result = try cache.copyRetained(source)
        lock.lock()
        let accepted = !finished
        if accepted { copies.append(Copy(url: result.url, lease: result.lease)) }
        lock.unlock()
        guard accepted else {
            result.lease.release()
            cache.discard(result.url)
            throw CocoaError(.userCancelled)
        }
        return result.url
    }

    func deliver() {
        lock.lock()
        for index in copies.indices { copies[index].delivered = true }
        lock.unlock()
    }

    func discard(_ url: URL) {
        lock.lock()
        let copy = copies.first { $0.url == url && !$0.delivered }
        if copy != nil { copies.removeAll { $0.url == url } }
        lock.unlock()
        if let copy { release(copy) }
    }

    func finish() {
        lock.lock()
        finished = true
        let completed = copies
        copies = []
        lock.unlock()
        completed.forEach(release)
    }

    private func release(_ copy: Copy) {
        copy.lease.release()
        if !copy.delivered { cache.discard(copy.url) }
    }

    deinit { finish() }
}

/// Owns clipboard monitoring only while an export is on the clipboard. This
/// remains active when Shelf UI is disabled, since the external consumer survives it.
@MainActor
final class ShelfExportCoordinator {
    let cache: ShelfExportCache
    private let changeCount: () -> Int
    private let pollInterval: TimeInterval
    private var clipboard: (version: Int, session: ShelfExportSession)?
    private var timer: Timer?

    init(cache: ShelfExportCache = ShelfExportStorage.cache, pollInterval: TimeInterval = 2,
         changeCount: @escaping () -> Int = { NSPasteboard.general.changeCount }) {
        self.cache = cache
        self.pollInterval = pollInterval
        self.changeCount = changeCount
    }

    func makeSession() -> ShelfExportSession { ShelfExportSession(cache: cache) }

    func keepOnClipboard(_ session: ShelfExportSession) {
        clipboard?.session.finish()
        session.deliver()
        clipboard = (changeCount(), session)
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshClipboard() }
        }
        timer.tolerance = min(pollInterval / 4, 0.5)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refreshClipboard() {
        guard let clipboard, clipboard.version != changeCount() else { return }
        self.clipboard = nil
        clipboard.session.finish()
        timer?.invalidate()
        timer = nil
    }

    deinit { timer?.invalidate() }
}

@MainActor
final class ShelfSharingSession: NSObject, NSSharingServiceDelegate, @preconcurrency NSSharingServicePickerDelegate {
    var picker: NSSharingServicePicker?
    var service: NSSharingService?
    private let export: ShelfExportSession
    private var onFinish: (() -> Void)?
    private var onServiceChosen: (() -> Void)?

    init(export: ShelfExportSession, onServiceChosen: (() -> Void)? = nil, onFinish: @escaping () -> Void) {
        self.export = export
        self.onFinish = onFinish
        self.onServiceChosen = onServiceChosen
        super.init()
        export.deliver()
    }

    private func finish() {
        guard let completion = onFinish else { return }
        onFinish = nil
        onServiceChosen = nil
        export.finish()
        picker?.delegate = nil
        picker?.close()
        service?.delegate = nil
        picker = nil
        service = nil
        completion()
    }

    func cancel() { finish() }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) { finish() }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) { finish() }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        guard onFinish != nil else { return nil }
        service = sharingService
        return self
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        if service == nil { finish() }
        else {
            let chosen = onServiceChosen
            onServiceChosen = nil
            chosen?()
        }
    }
}
