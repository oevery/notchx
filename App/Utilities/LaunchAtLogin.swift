import ServiceManagement
import Combine

/// System registration is authoritative; a failed write never leaves a guessed UI value.
@MainActor
final class LaunchAtLoginState: ObservableObject {
    static let shared = LaunchAtLoginState()
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?
    private let read: () -> Bool
    private let write: (Bool) throws -> Void

    init(read: @escaping () -> Bool = { LaunchAtLogin.isEnabled },
         write: @escaping (Bool) throws -> Void = { try LaunchAtLogin.setEnabled($0) }) {
        self.read = read
        self.write = write
        refresh()
    }

    func refresh() { isEnabled = read() }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do { try write(enabled) }
        catch { errorMessage = error.localizedDescription }
        refresh()
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        guard isEnabled != enabled else { return }
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

}
