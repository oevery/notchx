import Combine
import Foundation

@MainActor
final class AgentIntegrationController: ObservableObject {
    @Published private(set) var isInstalled = false
    @Published private(set) var hasRefreshed = false
    @Published private(set) var isWorking = false
    @Published private(set) var errorKey: String?
    @Published private(set) var helperStatus = CodexHelperStatus.unavailable
    let configuration: CodexHookConfiguration
    private let bundledHelper: URL
    private var refreshGeneration = UUID()

    init(configuration: CodexHookConfiguration = .standard, bundledHelper: URL? = nil) {
        self.configuration = configuration
        self.bundledHelper = bundledHelper ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NotchXAgentBridge")
    }

    var preview: String { (try? configuration.preview()) ?? "" }
    private var automation: CodexHookAutomation? {
        let standard = CodexHookConfiguration.standard
        guard configuration.root.standardizedFileURL == standard.root.standardizedFileURL,
              configuration.helper.standardizedFileURL == standard.helper.standardizedFileURL,
              ProcessInfo.processInfo.environment["NOTCHX_UNIT_TEST_HOST"] != "1" else { return nil }
        return .shared
    }

    func refresh() async {
        let expected = UUID()
        refreshGeneration = expected
        let configuration = configuration, bundledHelper = bundledHelper
        let (installed, helperStatus) = await Task.detached(priority: .utility) {
            (configuration.isInstalled(), configuration.helperStatus(bundledHelper: bundledHelper))
        }.value
        guard refreshGeneration == expected else { return }
        isInstalled = installed
        self.helperStatus = helperStatus
        hasRefreshed = true
    }

    func install() {
        automation?.allowInstallation()
        let helper = bundledHelper
        perform {
            try $0.setRuntimeEnabled(false)
            try $0.install(bundledHelper: helper)
        }
    }

    func updateHelper() {
        let helper = bundledHelper
        perform { try $0.updateHelper(bundledHelper: helper) }
    }

    func remove() {
        automation?.pauseInstallation()
        perform { try $0.remove() }
    }

    private func perform(_ action: @escaping @Sendable (CodexHookConfiguration) throws -> Void) {
        guard !isWorking else { return }
        isWorking = true
        errorKey = nil
        let configuration = configuration
        let automation = automation
        Task { [weak self] in
            await automation?.finish()
            let errorKey: String? = await Task.detached(priority: .utility) {
                do { try action(configuration); return nil }
                catch CodexHookConfigurationError.missingHelper { return "The native hook helper is missing. Build the complete app bundle." }
                catch { return "Cannot update hooks. Review file ownership, symbolic links, and configuration syntax." }
            }.value
            guard let self else { return }
            self.errorKey = errorKey
            self.isWorking = false
            if errorKey == nil { self.automation?.refresh() }
            await self.refresh()
        }
    }
}
