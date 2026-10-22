import Foundation
import IOKit
import Combine

final class KeyboardBacklightManager: ObservableObject {
    static let shared = KeyboardBacklightManager()

    @Published var brightness: Float = 0.5

    private var refreshToken: ModuleRefreshToken?
    private var connect: io_connect_t = 0
    private var serviceInitialized = false
    private var isEnabled = false
    private var lifecycleGeneration = UUID()

    private init() {}

    /// Reserved native capability: no current UI consumer, so the registry does
    /// not enable it. Merely resolving the singleton must not open hardware.
    @MainActor func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        lifecycleGeneration = UUID()
        if enabled {
            setupService()
            if serviceInitialized { updateBrightness(); startPolling() }
        } else {
            ModuleRefreshScheduler.shared.unregister(refreshToken)
            refreshToken = nil
            if serviceInitialized { IOServiceClose(connect) }
            serviceInitialized = false
            connect = 0
        }
    }

    // MARK: - IOKit Service Setup

    private func setupService() {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleLMUController")
        )

        guard service != 0 else { return }

        let result = IOServiceOpen(service, mach_task_self_, 0, &connect)
        IOObjectRelease(service)

        serviceInitialized = result == kIOReturnSuccess
    }

    // MARK: - Reading

    private func updateBrightness() {
        guard isEnabled, serviceInitialized else { return }
        let generation = lifecycleGeneration

        let inputCount: UInt32 = 1
        var input: [UInt64] = [0]
        var outputCount: UInt32 = 1
        var output: [UInt64] = [0]

        let result = IOConnectCallScalarMethod(
            connect,
            1, // getKeyboardBacklightBrightness
            &input, inputCount,
            &output, &outputCount
        )

        if result == kIOReturnSuccess {
            let rawValue = Float(output[0]) / 0xFFF // Max value
            DispatchQueue.main.async {
                guard self.isEnabled, self.lifecycleGeneration == generation else { return }
                self.brightness = rawValue
            }
        }
    }

    // MARK: - Polling

    private func startPolling() {
        let generation = lifecycleGeneration
        Task { @MainActor [weak self] in
            guard let self, self.isEnabled, self.lifecycleGeneration == generation, self.refreshToken == nil else { return }
            self.refreshToken = ModuleRefreshScheduler.shared.register(
                id: "volume.keyboardBacklight",
                name: "Keyboard backlight refresh",
                module: .builtIn(.volumeHUD),
                policy: .visibleOnly(2, tolerance: 0.5),
                enabled: { [weak self] in self?.isEnabled == true }
            ) { [weak self] in
                self?.updateBrightness()
            }
        }
    }

    // MARK: - Control

    func setBrightness(_ newBrightness: Float) {
        guard isEnabled, serviceInitialized else { return }

        let rawValue = UInt64(max(0, min(1, newBrightness)) * Float(0xFFF))
        let inputCount: UInt32 = 2
        var input: [UInt64] = [0, rawValue]
        var outputCount: UInt32 = 1
        var output: [UInt64] = [0]

        IOConnectCallScalarMethod(
            connect,
            2, // setKeyboardBacklightBrightness
            &input, inputCount,
            &output, &outputCount
        )
    }

    // MARK: - Helpers

    var brightnessPercentage: Int {
        Int(brightness * 100)
    }

    deinit {
        let token = refreshToken
        Task { @MainActor in
            ModuleRefreshScheduler.shared.unregister(token)
        }
        if serviceInitialized {
            IOServiceClose(connect)
        }
    }
}
