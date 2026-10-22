import AppKit
import SwiftUI

enum OnboardingLayout {
    static let windowSize = CGSize(width: 680, height: 560)
}

/// Setup is informational. Permissions are requested only from explicit controls
/// in Settings or the native module that needs them.
struct OnboardingView: View {
    let onComplete: () -> Void
    let onOpenSettings: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack {
                Label("NotchX", systemImage: "rectangle.topthird.inset.filled")
                    .font(.title)
                Spacer()
                LanguagePicker().frame(width: 240)
            }
            Divider()
            Group {
                switch step {
                case 0:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Welcome to NotchX").font(.largeTitle)
                        Text("Your native island for everyday Mac activities.")
                        Text("Now Playing, Volume HUD, Battery, Shelf, Connectivity, Calendar, Weather, Notifications, and Teleprompter are built in.")
                        Text("Choose the modules you want in Settings. No extension downloads or account are required.")
                            .foregroundStyle(.secondary)
                    }
                case 1:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Use the island").font(.largeTitle)
                        Label("Hover over the island to peek at an activity.", systemImage: "cursorarrow")
                        Label("Click to expand the current activity.", systemImage: "cursorarrow.click")
                        Label("Swipe left or right on the notch to switch between modules.", systemImage: "hand.draw")
                        Text("Adjust hover delay, motion, and module preferences in Settings.")
                            .foregroundStyle(.secondary)
                    }
                default:
                    VStack(alignment: .leading, spacing: 16) {
                        Text("You're all set").font(.largeTitle)
                        Text("NotchX runs in the background and stays available from the menu bar.")
                        Text("Permissions are optional. Use Grant Access in Settings when you want a feature that needs access.")
                        Text("NotchX updates are installed manually. Automatic update checks and telemetry are disabled.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
            HStack {
                if step > 0 { Button("Back") { step -= 1 } }
                Spacer()
                if step < 2 {
                    Button("Continue") { step += 1 }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Open Settings") { onOpenSettings() }
                    Button("Get Started") { onComplete() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(32)
        .frame(width: OnboardingLayout.windowSize.width, height: OnboardingLayout.windowSize.height)
        .notchXLocalized()
    }
}
