import SwiftUI

struct PlaybackFavoriteButton: View {
    let context: String
    var controlsPending = false
    var beginInteraction: () -> Void = {}
    @Environment(\.islandContentActive) private var contentActive
    @StateObject private var controller = PlaybackFavoriteController()

    private var currentState: Bool? { controller.context == context ? controller.state : nil }
    private var label: String {
        if controller.needsPermission { return L10n.text("Enable Accessibility for NotchX to use favorites") }
        if currentState == nil && !controller.error { return L10n.text("Favorite state unavailable") }
        if controller.isPending { return L10n.text("Updating favorite…") }
        if controller.error { return L10n.text("Could not confirm favorite. Try again shortly.") }
        return L10n.text(currentState == true ? "Remove from favorites" : "Add to favorites")
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                guard contentActive, !controlsPending else { return }
                beginInteraction()
                if controller.needsPermission {
                    PermissionsManager.shared.openAccessibilitySettings()
                } else {
                    controller.toggle(context: context)
                }
            } label: {
                Group {
                    if controller.isPending {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: controller.error ? "exclamationmark.circle" : (currentState == true ? "heart.fill" : "heart"))
                            .foregroundStyle(currentState == true ? Color.pink : Color.secondary)
                    }
                }
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled((currentState == nil && !controller.needsPermission) || controller.isPending)
            .help(label)
            .accessibilityLabel(label)
            .accessibilityValue(currentState.map { L10n.text($0 ? "Liked" : "Not liked") } ?? L10n.text("Unknown"))
        }
        .task(id: contentActive ? context : nil) {
            guard contentActive else { controller.reset(context: nil); return }
            controller.reset(context: context)
            await controller.refresh()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                await controller.refresh()
            }
        }
        .onChange(of: context) { _, newContext in
            if controller.context != newContext { controller.reset(context: newContext) }
        }
        .onChange(of: contentActive) { _, active in
            if !active { controller.reset(context: nil) }
        }
        .onChange(of: controlsPending) { _, pending in
            if pending { controller.cancelOperation() }
        }
        .onDisappear { controller.reset(context: nil) }
    }
}
