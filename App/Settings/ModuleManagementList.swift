import SwiftUI
import UniformTypeIdentifiers

private enum ModuleOrderDrag {
    static let contentType = UTType(exportedAs: "app.notchx.module-order", conformingTo: .data)
}

struct ModuleManagementList: View {
    @ObservedObject var appState: AppState
    @Environment(\.islandMotion) private var motion
    @State private var draggedItems: [ModuleType] = []
    @State private var previewWidth: CGFloat = 540
    let showDetails: (ModuleType) -> Void

    private var modules: [ModuleType] { appState.orderedModules }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(modules) { module in
                accessibleRow(module)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { previewWidth = $0 }
        .modifier(ModuleManagementDragModifier(appState: appState, draggedItems: $draggedItems,
            previewWidth: previewWidth, showDetails: showDetails))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("module-management-list")
    }

    private func accessibleRow(_ module: ModuleType) -> some View {
        let position = (modules.firstIndex(of: module) ?? 0) + 1
        return draggableRow(module)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("module-row-" + module.rawValue)
            .accessibilityLabel(L10n.text(module.title))
            .accessibilityValue(L10n.format("Position %d of %d", position, modules.count))
            .accessibilityHint(Text(L10n.text("Drag to reorder. Right-click for Move Up or Move Down.")))
            .accessibilityActions {
                if draggedItems.isEmpty, module != modules.first {
                    Button(L10n.text("Move Up")) { move(module, by: -1) }
                }
                if draggedItems.isEmpty, module != modules.last {
                    Button(L10n.text("Move Down")) { move(module, by: 1) }
                }
            }
    }

    private func draggableRow(_ module: ModuleType) -> some View {
        ModuleManagementRow(appState: appState, module: module, showDetails: showDetails)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) {
                if module != modules.last { Divider().allowsHitTesting(false) }
            }
            .draggableItem(module)
            .contextMenu {
                Button(L10n.text("Move Up")) { move(module, by: -1) }
                    .disabled(!draggedItems.isEmpty || module == modules.first)
                Button(L10n.text("Move Down")) { move(module, by: 1) }
                    .disabled(!draggedItems.isEmpty || module == modules.last)
            }
    }

    private func move(_ module: ModuleType, by offset: Int) {
        guard draggedItems.isEmpty else { return }
        withAnimation(motion.reduced ? nil : .default.speed(2)) { appState.moveModule(module, by: offset) }
    }
}

/// Business wiring between the unchanged Maccy container and AppState's order command.
struct ModuleManagementDragModifier: ViewModifier {
    @ObservedObject var appState: AppState
    @Binding var draggedItems: [ModuleType]
    @Environment(\.islandMotion) private var motion
    let previewWidth: CGFloat
    let showDetails: (ModuleType) -> Void

    func body(content: Content) -> some View {
        content.draggableContainer(
            items: appState.orderedModules, contentType: ModuleOrderDrag.contentType,
            dragPreview: { items in
                VStack(spacing: 0) {
                    ForEach(items) { module in
                        ModuleManagementRow(appState: appState, module: module, showDetails: showDetails)
                    }
                }
                .frame(width: previewWidth)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            },
            draggedItems: $draggedItems,
            moveAction: move
        )
    }

    private func move(from source: IndexSet, to destination: Int) {
        withAnimation(motion.reduced ? nil : .default.speed(2)) {
            appState.moveModules(from: source, to: destination)
        }
    }
}

private struct ModuleManagementRow: View {
    @ObservedObject var appState: AppState
    let module: ModuleType
    let showDetails: (ModuleType) -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary).frame(width: 20)
                .accessibilityHidden(true)
            Text(L10n.text(module.title))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("settings-label-" + module.title)
            SettingSwitch(title: module.title, isOn: module.enabledBinding(in: appState))
                .dataAnnotationID("module-toggle-" + module.rawValue)
            Button(L10n.text("Details")) { showDetails(module) }
                .accessibilityLabel(L10n.format("%@ settings", L10n.text(module.title)))
        }
        .font(.body).controlSize(.regular)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 46)
    }
}
