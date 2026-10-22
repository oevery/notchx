import SwiftUI

/// Pages overlap during a short fade; their heights must never be stacked.
struct IslandPageTransition<Key: Hashable, Content: View>: View {
    @Environment(\.islandMotion) private var motion
    let key: Key
    @ViewBuilder var content: () -> Content
    var body: some View {
        ZStack(alignment: .topLeading) { content().id(key).transition(.opacity) }
            .animation(motion.content, value: key)
    }
}

/// A disclosure's arrow/text form its entire hit area. The caller owns state
/// and content placement, including disclosures controlled from a fixed footer.
struct IslandDisclosureButton<Label: View>: View {
    @Environment(\.islandMotion) private var motion
    let expanded: Bool
    let action: () -> Void
    @ViewBuilder var label: () -> Label
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .accessibilityHidden(true)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .animation(motion.content, value: expanded)
                label()
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).fixedSize()
        .accessibilityValue(expanded ? L10n.text("Expanded") : L10n.text("Collapsed"))
    }
}

/// Natural heights are measured without implicit row-layout animation. Only
/// the host animates the enclosing viewport; inner controls can animate locally.
struct IslandNaturalLayout: ViewModifier {
    func body(content: Content) -> some View { content.transaction { $0.animation = nil } }
}
