import SwiftUI
import AppKit

struct SystemHUDExpandedView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.islandPresentationState) private var presentationState
    @ObservedObject private var volumeManager = VolumeManager.shared

    @State private var overshootScale: CGFloat = 1.0

    var body: some View {
        Group {
            if appState.activeBuiltInModule == .volumeHUD && (presentationState ?? appState.currentState) == .fullExpanded {
                fullExpandedVolumeView
            } else {
                defaultHUDView
            }
        }
        .onChange(of: currentValue) { _, newValue in
            if newValue <= 0 || newValue >= 1.0 {
                triggerOvershoot()
            }
        }
    }

    private var defaultHUDView: some View {
        HStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(.white)
                .scaleEffect(overshootScale)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.text(label))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    Text("\(currentPercentage)%")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                }

                SliderBar(value: currentBinding)
                    .disabled(!volumeManager.canSetVolume)

                if appState.activeBuiltInModule == .volumeHUD {
                    Text(volumeManager.outputDeviceName)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
            }
        }
    }

    private var fullExpandedVolumeView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker(L10n.text("Output device"), selection: Binding(get: { volumeManager.selectedOutputDeviceID }, set: { volumeManager.selectOutputDevice($0) })) {
                    ForEach(volumeManager.outputDevices) { device in Label(device.name, systemImage: device.icon).tag(device.id) }
                }.labelsHidden().accessibilityIdentifier("volume-output-device")
                Button(volumeManager.isMuted ? L10n.text("Unmute") : L10n.text("Mute")) { volumeManager.toggleMute() }.disabled(!volumeManager.canMute)
                    .accessibilityIdentifier("volume-mute")
            }
            HStack(spacing: 12) {
                Image(systemName: volumeManager.volumeIconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .scaleEffect(overshootScale)

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("System Volume")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white)
                        Spacer()
                        Text("\(volumeManager.volumePercentage)%")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    SliderBar(value: currentBinding)
                        .disabled(!volumeManager.canSetVolume)
                }
            }

            Text(volumeManager.outputDeviceName)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
            if !volumeManager.canSetVolume {
                Text("This output device does not support system volume control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let error = volumeManager.controlError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }

            Divider()
                .overlay(.white.opacity(0.15))

            Text("Media Apps")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.8))
            Text("Media app sliders support selected players and browser media only. They are not a system-wide app mixer.")
                .font(.caption2).foregroundStyle(.secondary)

            if volumeManager.mediaAppVolumes.isEmpty {
                Text("No supported media apps are currently playing.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                StableScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 8) {
                        ForEach(volumeManager.mediaAppVolumes.prefix(5)) { app in
                            MediaAppVolumeRow(app: app) { newValue in
                                volumeManager.setMediaAppVolume(appID: app.id, volume: newValue)
                            }
                        }
                    }
                    .padding(.trailing, 2)
                }
                .frame(maxHeight: 106)
            }
        }
        .onAppear {
            volumeManager.refreshOutputDevices()
            volumeManager.refreshMediaAppVolumes()
        }
    }

    private var iconName: String {
        switch appState.activeBuiltInModule {
        case .volumeHUD: return volumeManager.volumeIconName
        default: return "speaker.wave.2.fill"
        }
    }

    private var label: String {
        switch appState.activeBuiltInModule {
        case .volumeHUD: return "Volume"
        default: return ""
        }
    }

    private var currentValue: Float {
        switch appState.activeBuiltInModule {
        case .volumeHUD: return volumeManager.volume
        default: return 0
        }
    }

    private var currentPercentage: Int {
        Int(currentValue * 100)
    }

    private var currentBinding: Binding<Float> {
        switch appState.activeBuiltInModule {
        case .volumeHUD:
            return Binding(
                get: { volumeManager.volume },
                set: { volumeManager.setVolume($0) }
            )
        default:
            return .constant(0)
        }
    }

    private func triggerOvershoot() {
        withAnimation(Constants.overshootBounce) {
            overshootScale = 1.15
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(Constants.overshootBounce) {
                overshootScale = 1.0
            }
        }
    }
}

private struct MediaAppVolumeRow: View {
    let app: MediaAppVolume
    let onChange: (Float) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let appIcon = appIconImage {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 14, height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    Image(systemName: app.iconName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .frame(width: 14)
                }

                Text(app.appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)

                Spacer()

                Text(app.statusText)
                    .font(.system(size: 10))
                    .foregroundColor(app.isPlaying ? .green : .white.opacity(0.55))

                Text("\(Int(app.volume * 100))%")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.72))
            }

            SliderBar(
                value: Binding(
                    get: { app.volume },
                    set: { onChange($0) }
                )
            )
            .accessibilityLabel(Text(app.appName))
        }
    }

    private var appIconImage: NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}

// MARK: - Slider Bar

struct SliderBar: View {
    @EnvironmentObject private var appState: AppState
    @Binding var value: Float
    @State private var interaction: IslandInteractionToken?
    @Environment(\.islandContentActive) private var contentActive

    var body: some View {
        Slider(value: $value, in: 0...1) { editing in
            if editing {
                guard interaction == nil else { return }
                interaction = appState.beginControlInteraction(for: .volumeHUD)
            } else { endDragging() }
        }
        .accessibilityLabel(Text("Volume"))
        .onChange(of: contentActive) { _, active in if !active { endDragging() } }
        .onDisappear { endDragging() }
    }

    private func endDragging() {
        guard let interaction else { return }
        self.interaction = nil
        appState.endControlInteraction(interaction)
    }
}
