import SwiftUI

struct WeatherFreshnessView: View {
    @ObservedObject var manager: WeatherManager
    @Environment(\.islandContentActive) private var contentActive
    var body: some View {
        if let updated = manager.lastUpdated {
            if contentActive {
                TimelineView(.periodic(from: Date(), by: 60)) { context in label(updated: updated, now: context.date) }
            } else { label(updated: updated, now: Date()) }
        }
    }
    private func label(updated: Date, now: Date) -> some View {
        HStack(spacing: 4) {
            Text("Updated")
            Text(updated, style: .time)
            if manager.isStale(at: now) { Text("Outdated forecast").foregroundStyle(.orange) }
        }.font(.caption2).foregroundStyle(.secondary)
    }
}
