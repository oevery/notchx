import AppKit
import SwiftUI

struct IslandAppearance: Equatable, Sendable {
    let usesFrostedBackdrop: Bool
    let increasedContrast: Bool

    init(compact: Bool = false, reduceTransparency: Bool = false, increasedContrast: Bool = false) {
        usesFrostedBackdrop = !(compact || reduceTransparency || increasedContrast)
        self.increasedContrast = increasedContrast
    }
}

extension EnvironmentValues {
    @Entry var islandAppearance = IslandAppearance()

    var basicControlSize: BasicControlSize {
        controlSize == .small ? .small : .regular
    }
}

enum BasicControlSize: CaseIterable {
    case regular, small

    var swiftUISize: ControlSize { self == .small ? .small : .regular }
    var appKitSize: NSControl.ControlSize { self == .small ? .small : .regular }
    var islandHeight: CGFloat { self == .small ? 24 : 32 }
    var horizontalInset: CGFloat { self == .small ? 7 : 10 }
    var verticalInset: CGFloat { self == .small ? 3 : 5 }
    var islandRadius: CGFloat { self == .small ? 7 : 9 }
    var islandPointSize: CGFloat { self == .small ? 11 : 13 }
    var islandFont: Font { .system(size: islandPointSize, weight: .medium) }
}

extension View {
    func basicControlSize(_ size: BasicControlSize) -> some View { controlSize(size.swiftUISize) }

    func islandInputChrome(insetsContent: Bool = true) -> some View {
        modifier(IslandInputChrome(insetsContent: insetsContent))
    }
}

private struct IslandInputChrome: ViewModifier {
    @Environment(\.basicControlSize) private var size
    @Environment(\.islandAppearance) private var appearance
    @Environment(\.isEnabled) private var isEnabled
    let insetsContent: Bool

    func body(content: Content) -> some View {
        let paint = IslandActionPaint(isPrimary: false, isEnabled: isEnabled, isHovered: false,
                                     isPressed: false, appearance: appearance)
        let shape = RoundedRectangle(cornerRadius: size.islandRadius, style: .continuous)
        content
            .font(size.islandFont)
            .foregroundStyle(paint.foreground)
            .padding(.horizontal, insetsContent ? size.horizontalInset : 0)
            .padding(.vertical, insetsContent ? size.verticalInset : 0)
            .frame(minHeight: size.islandHeight)
            .background {
                shape.fill(paint.fill)
                    .overlay { shape.strokeBorder(paint.border, lineWidth: 1) }
                    .allowsHitTesting(false)
            }
    }
}

enum IslandNativeAppearance {
    static func name(increasedContrast: Bool) -> NSAppearance.Name {
        increasedContrast ? .accessibilityHighContrastDarkAqua : .darkAqua
    }
}

struct IslandNativePopoverSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.bordered)
            .environment(\.colorScheme, .dark)
            .preferredColorScheme(.dark)
    }
}

struct IslandMenuItem {
    let title: String
    var symbol: String? = nil
    var isEnabled = true
    let action: () -> Void

    func hasSamePresentation(as other: Self) -> Bool {
        title == other.title && symbol == other.symbol && isEnabled == other.isEnabled
    }
}

struct IslandMenuButton: NSViewRepresentable {
    @EnvironmentObject private var appState: AppState
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.islandContentActive) private var contentActive
    @Environment(\.islandAppearance) private var appearance
    @Environment(\.basicControlSize) private var size
    let label: String
    var title = ""
    var symbol: String? = nil
    var identifier = ""
    let module: ModuleType?
    let items: [IslandMenuItem]
    var selectedIndex: Int? = nil
    var focusRequest: UUID? = nil
    var usesSharedBezel = true

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: selectedIndex == nil)
        if usesSharedBezel {
            button.cell = IslandMenuButtonCell(textCell: "", pullsDown: selectedIndex == nil)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.hold = contentActive ? { appState.beginControlInteraction(for: module) } : nil
        coordinator.release = { appState.endControlInteraction($0) }
        if !contentActive {
            if coordinator.isTracking { button.menu?.cancelTracking() }
            coordinator.close()
        }
        button.isEnabled = isEnabled && contentActive && !items.isEmpty
        guard let menu = button.menu, !coordinator.isTracking else { return }
        let appearanceName = IslandNativeAppearance.name(increasedContrast: appearance.increasedContrast)
        if menu.appearance?.name != appearanceName {
            let nativeAppearance = NSAppearance(named: appearanceName)
            button.appearance = nativeAppearance
            menu.appearance = nativeAppearance
        }
        button.isBordered = false
        (button.cell as? IslandMenuButtonCell)?.horizontalInset = size.horizontalInset
        if button.controlSize != size.appKitSize { button.controlSize = size.appKitSize }
        let font = NSFont.systemFont(ofSize: size.islandPointSize, weight: .medium)
        if button.font != font { button.font = font }
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)

        let pullsDown = selectedIndex == nil
        if coordinator.updateItems(items, title: title, symbol: symbol) || button.pullsDown != pullsDown {
            button.pullsDown = pullsDown
            menu.removeAllItems()
            if pullsDown {
                let header = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                header.image = Self.image(symbol)
                menu.addItem(header)
            }
            for (index, entry) in items.enumerated() {
                let item = NSMenuItem(title: entry.title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.tag = index
                item.image = Self.image(entry.symbol)
                item.target = coordinator
                item.isEnabled = entry.isEnabled
                menu.addItem(item)
            }
            button.invalidateIntrinsicContentSize()
        }
        if let selectedIndex, menu.items.indices.contains(selectedIndex), button.indexOfSelectedItem != selectedIndex {
            button.selectItem(at: selectedIndex)
            button.invalidateIntrinsicContentSize()
        }
        coordinator.restoreFocus(focusRequest, to: button)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView button: NSPopUpButton, context: Context) -> CGSize? {
        guard usesSharedBezel else { return nil }
        let intrinsic = button.intrinsicContentSize
        return CGSize(width: intrinsic.width + 2 * size.horizontalInset,
                      height: max(intrinsic.height, size.islandHeight))
    }

    static func dismantleNSView(_ button: NSPopUpButton, coordinator: Coordinator) {
        if coordinator.isTracking { button.menu?.cancelTracking() }
        coordinator.close()
    }

    private static func image(_ symbol: String?) -> NSImage? {
        symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var hold: (() -> IslandInteractionToken)?
        var release: ((IslandInteractionToken) -> Void)?
        private(set) var isTracking = false
        private var items: [IslandMenuItem] = []
        private var title: String?
        private var symbol: String?
        private var token: IslandInteractionToken?
        private var focusRequest: UUID?

        func updateItems(_ items: [IslandMenuItem], title: String, symbol: String?) -> Bool {
            let changed = self.title != title || self.symbol != symbol || self.items.count != items.count
                || !zip(self.items, items).allSatisfy { $0.hasSamePresentation(as: $1) }
            self.items = items
            self.title = title
            self.symbol = symbol
            return changed
        }

        func menuWillOpen(_ menu: NSMenu) {
            guard !isTracking else { return }
            isTracking = true
            token = hold?()
        }

        func menuDidClose(_ menu: NSMenu) { close() }

        func close() {
            isTracking = false
            if let token { release?(token) }
            token = nil
        }

        @objc func choose(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag), items[sender.tag].isEnabled else { return }
            items[sender.tag].action()
        }

        func restoreFocus(_ request: UUID?, to button: NSPopUpButton) {
            guard let request, request != focusRequest else { return }
            focusRequest = request
            Task { @MainActor [weak self, weak button] in
                guard self?.focusRequest == request, let button, button.isEnabled,
                      let window = button.window, window.isKeyWindow else { return }
                window.makeFirstResponder(button)
            }
        }
    }
}

private final class IslandMenuButtonCell: NSPopUpButtonCell {
    var horizontalInset: CGFloat = 0

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.draw(withFrame: cellFrame.insetBy(dx: horizontalInset, dy: 0), in: controlView)
    }
}

enum IslandPalette: ShapeStyle {
    case primary, label, secondary, tertiary, icon, separator

    func resolve(in environment: EnvironmentValues) -> Color {
        color(for: environment.islandAppearance)
    }

    func color(for appearance: IslandAppearance) -> Color {
        let level: Double
        switch (self, appearance.increasedContrast) {
        case (.primary, true): level = 0.99
        case (.label, true), (.icon, true): level = 0.96
        case (.secondary, true): level = 0.91
        case (.tertiary, true): level = 0.86
        case (.primary, false): level = 0.89
        case (.label, false): level = 0.83
        case (.icon, false): level = 0.80
        case (.secondary, false): level = 0.75
        case (.tertiary, false): level = 0.69
        case (.separator, true): return .white.opacity(0.34)
        case (.separator, false): return .white.opacity(0.14)
        }
        return Color(red: level - 0.01, green: level, blue: min(1, level + 0.02))
    }

    static let disabled = Color(white: 0.60)
    static let attention = Color(red: 0.96, green: 0.78, blue: 0.53)
    static let selected = Color(red: 0.78, green: 0.84, blue: 0.96).opacity(0.14)
    static let hover = Color.white.opacity(0.08)
    static let pressed = Color.white.opacity(0.14)
}

struct IslandDivider: View {
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle().fill(IslandPalette.separator)
            .frame(height: 1 / displayScale)
            .accessibilityHidden(true)
    }
}

enum IslandTypography {
    static let heading = Font.system(size: 13, weight: .medium)
    static let secondary = Font.system(size: 12)
    static let metadata = Font.system(size: 11)
    static let time = Font.system(size: 11, design: .monospaced)
}

struct IslandSurfaceBackground<S: Shape>: View, Animatable {
    var shape: S
    let appearance: IslandAppearance

    var animatableData: S.AnimatableData {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    var body: some View {
        Group {
            if appearance.usesFrostedBackdrop {
                GeometryReader { geometry in
                    let bounds = CGRect(origin: .zero, size: geometry.size)
                    ZStack {
                        IslandBackdrop(path: shape.path(in: bounds).cgPath, size: bounds.size)
                        shape.fill(.black.opacity(0.56))
                        shape.fill(LinearGradient(
                            colors: [.black, .black.opacity(0.8), .clear], startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 40 / max(40, bounds.height))
                        ))
                    }
                }
            } else {
                shape.fill(.black)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct IslandBackdrop: NSViewRepresentable {
    let path: CGPath
    let size: CGSize

    func makeNSView(context: Context) -> BackdropView {
        let view = BackdropView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ view: BackdropView, context: Context) {
        view.updateMask(path: path, size: size)
    }

    final class BackdropView: NSVisualEffectView {
        private var maskPath: CGPath?
        private var maskSize = CGSize.zero

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func updateMask(path: CGPath, size: CGSize) {
            isHidden = size.width <= 0 || size.height <= 0
            guard !isHidden, maskPath != path || maskSize != size else { return }
            maskPath = path
            maskSize = size
            maskImage = NSImage(size: size, flipped: true) { _ in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.setFillColor(NSColor.white.cgColor)
                context.addPath(path)
                context.fillPath()
                return true
            }
        }
    }
}

struct IslandActionPaint {
    let isPrimary: Bool
    let isEnabled: Bool
    let isHovered: Bool
    let isPressed: Bool
    let appearance: IslandAppearance

    var foreground: Color {
        if !isEnabled { return IslandPalette.disabled }
        if isPrimary { return Color(white: 0.09) }
        return IslandPalette.label.color(for: appearance)
    }

    var fill: Color {
        if !isEnabled { return Color(white: 0.16) }
        if isPrimary {
            let level = appearance.increasedContrast ? 0.93 : 0.76
            return Color(white: level + (isPressed ? -0.09 : isHovered ? 0.05 : 0))
        }
        return Color(white: 0.19 + (isPressed ? 0.08 : isHovered ? 0.04 : 0))
    }

    var border: Color {
        .white.opacity(isPrimary ? 0 : !isEnabled ? 0.10 : appearance.increasedContrast ? 0.55 : 0.24)
    }
}

/// Keep button semantics/native keyboard handling; share only appearance and feedback.
struct IslandButtonStyle: ButtonStyle {
    enum Kind {
        case quiet, secondary, primary, icon, navigation, row
    }
    var kind: Kind = .quiet
    var selected = false

    init(_ kind: Kind = .quiet, selected: Bool = false) {
        self.kind = kind
        self.selected = selected
    }

    func makeBody(configuration: Configuration) -> some View {
        IslandButtonBody(configuration: configuration, kind: kind, selected: selected)
    }
}

private struct IslandButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: IslandButtonStyle.Kind
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.islandAppearance) private var appearance
    @Environment(\.islandMotion) private var motion
    @Environment(\.basicControlSize) private var size
    @State private var hovering = false

    private var isPrimary: Bool { kind == .primary }
    private var padded: Bool { kind == .secondary || isPrimary }
    private var isSelected: Bool { isEnabled && selected && !isPrimary }
    private var actionPaint: IslandActionPaint {
        IslandActionPaint(isPrimary: isPrimary, isEnabled: isEnabled, isHovered: hovering,
                          isPressed: configuration.isPressed, appearance: appearance)
    }
    private var scale: CGFloat {
        configuration.isPressed && isEnabled && !reduceMotion && !motion.reduced && !padded && kind != .row ? 0.97 : 1
    }
    private var feedbackAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.08) : motion.feedback
    }
    private var interactionFill: Color {
        if padded || !isEnabled { return .clear }
        if configuration.isPressed { return IslandPalette.pressed }
        if hovering { return IslandPalette.hover }
        return .clear
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size.islandRadius, style: .continuous)
        configuration.label
            .font(size.islandFont)
            .foregroundStyle(actionPaint.foreground)
            .padding(.horizontal, padded ? size.horizontalInset : 0)
            .padding(.vertical, padded ? size.verticalInset : 0)
            .frame(minWidth: kind == .icon || kind == .navigation ? size.islandHeight : nil,
                   minHeight: kind == .quiet || kind == .row ? nil : size.islandHeight)
            .background {
                shape.fill(padded ? actionPaint.fill : .clear)
                    .overlay { if isSelected { shape.fill(IslandPalette.selected) } }
                    .overlay { shape.fill(interactionFill) }
                    .overlay {
                        if padded { shape.strokeBorder(actionPaint.border, lineWidth: 1) }
                        else if isSelected { shape.strokeBorder(IslandPalette.separator, lineWidth: 1) }
                    }
            }
            .contentShape(shape)
            .scaleEffect(scale)
            .opacity(isEnabled || padded ? 1 : 0.55)
            .animation(feedbackAnimation, value: configuration.isPressed)
            .animation(feedbackAnimation, value: hovering && isEnabled)
            .onHover { hovering = $0 }
    }
}

struct IslandSectionHeading: View {
    let title: Text
    var body: some View {
        title
            .font(IslandTypography.heading)
            .foregroundStyle(IslandPalette.label)
    }
}

struct IslandStatusLabel: View {
    let title: Text
    var icon: String? = nil
    var needsAttention = false

    var body: some View {
        HStack(spacing: 5) {
            if let icon { Image(systemName: icon).accessibilityHidden(true) }
            title
        }
        .font(IslandTypography.secondary)
        .foregroundStyle(needsAttention ? AnyShapeStyle(IslandPalette.attention) : AnyShapeStyle(IslandPalette.secondary))
    }
}

struct IslandEmptyState: View {
    let icon: String
    let title: Text
    let subtitle: Text
    var fillsAvailableSpace = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium))
                .foregroundStyle(IslandPalette.icon).accessibilityHidden(true)
            IslandSectionHeading(title: title)
            subtitle.font(IslandTypography.secondary).foregroundStyle(IslandPalette.secondary)
                .multilineTextAlignment(.center).lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: fillsAvailableSpace ? .infinity : nil)
    }
}
