import Combine
import Foundation

@MainActor
final class PlaybackFavoriteController: ObservableObject {
    @Published private(set) var state: Bool?
    @Published private(set) var isPending = false
    @Published private(set) var error = false
    @Published private(set) var needsPermission = false
    private(set) var context: String?
    private let access: any FavoriteAccess
    private var revision = UUID()
    private var action: Task<Void, Never>?

    init(access: any FavoriteAccess = NetEaseFavoriteAccess()) { self.access = access }

    func reset(context: String?) {
        revision = UUID()
        action?.cancel()
        action = nil
        self.context = context
        state = nil
        isPending = false
        error = false
        needsPermission = false
    }

    func cancelOperation() {
        revision = UUID()
        action?.cancel()
        action = nil
        isPending = false
    }

    func refresh() async {
        guard context != nil, !isPending else { return }
        let request = revision
        let authorized = await access.isAuthorized()
        guard request == revision, !Task.isCancelled, !isPending else { return }
        needsPermission = !authorized
        guard authorized else {
            state = nil
            error = false
            return
        }
        let result = await access.read()
        guard request == revision, !Task.isCancelled, !isPending else { return }
        state = result
        if result != nil { error = false }
    }

    func toggle(context: String?) {
        guard let context, self.context == context, let previous = state, !isPending else { return }
        // Invalidate reads that started before this write.
        revision = UUID()
        let request = revision
        isPending = true
        error = false
        action = Task { [weak self] in
            guard let self else { return }
            let sent = await access.toggle(expected: previous)
            guard request == revision, !Task.isCancelled else { return }
            // Confirmation is authoritative. No optimistic toggle or write retry.
            if sent {
                for _ in 0..<6 {
                    let confirmed = await access.read()
                    guard request == revision, !Task.isCancelled else { return }
                    if confirmed == !previous {
                        state = confirmed
                        isPending = false
                        action = nil
                        return
                    }
                    do { try await Task.sleep(for: .milliseconds(300)) }
                    catch { return }
                }
            }
            guard request == revision, !Task.isCancelled else { return }
            state = nil
            error = true
            isPending = false
            action = nil
        }
    }
}
