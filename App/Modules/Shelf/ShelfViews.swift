import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ShelfCompactView: View {
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: shelf.isEmpty ? "tray" : "tray.full.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))

            if let latest = latestItem {
                Text(latest.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            } else {
                Text("Shelf")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }

            if !shelf.isEmpty {
                Text("\(shelf.visibleItems.count)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
            }
        }
    }

    private var latestItem: ShelfItem? {
        shelf.visibleItems.max { $0.addedAt < $1.addedAt }
    }
}

struct ShelfExpandedView: View {
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Shelf", systemImage: "tray.full.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)

                if !shelf.removingItemIDs.isEmpty { ProgressView().controlSize(.small) }
                if !shelf.removalFailures.isEmpty {
                    Label(L10n.format("%d failed", shelf.removalFailures.count), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.yellow)
                }

                Text(shelf.isEmpty ? L10n.text("Drop files, links, images, or text") : L10n.format("%d saved", shelf.visibleItems.count))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
            }

            if shelf.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.78))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Drop onto the island")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("Items stay here until you remove them.")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.56))
                    }
                }
            } else {
                StableScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(previewItems) { item in
                            ExpandedShelfChip(item: item)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var previewItems: [ShelfItem] {
        Array(shelf.visibleItems.sorted { $0.addedAt > $1.addedAt }.prefix(4))
    }
}

struct ShelfFullExpandedView: View {
    @ObservedObject private var shelf: ShelfStore
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @Environment(\.islandContentActive) private var contentActive
    @State private var selection = ShelfSelection()
    @State private var keyMonitor: Any?
    @State private var gridColumns = 1
    @FocusState private var searchFocused: Bool

    init(shelf: ShelfStore? = nil) {
        _shelf = ObservedObject(wrappedValue: shelf ?? .shared)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ShelfGridLayout.feedbackSpacing) {
            HStack(spacing: 12) {
                AirDropDropPane(shelf: shelf, selectedItems: selectedItems)
                    .frame(width: 124)
                TrayDropPane(
                    items: filteredItems,
                    totalCount: orderedItems.count,
                    isFiltering: !trimmedSearchText.isEmpty,
                    searchText: $searchText,
                    selection: $selection,
                    searchFocused: $searchFocused,
                    gridColumns: $gridColumns,
                    shelf: shelf
                )
                    .environmentObject(appState)
            }
            .frame(maxHeight: .infinity)
            ShelfImportFeedbackView(shelf: shelf)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(appState.motion.content, value: shelf.pendingRemoval?.itemIDs)
        .onAppear { if contentActive { installKeyMonitor() } }
        .onChange(of: contentActive) { _, active in
            if active { installKeyMonitor() } else { removeKeyMonitor() }
        }
        .onChange(of: filteredItems.map(\.id)) { _, ids in selection.reconcile(ids) }
        .onDisappear { removeKeyMonitor() }
    }

    private var orderedItems: [ShelfItem] {
        shelf.visibleItems.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned
            }
            return lhs.addedAt > rhs.addedAt
        }
    }

    private var filteredItems: [ShelfItem] {
        let query = trimmedSearchText.lowercased()
        guard !query.isEmpty else { return orderedItems }
        return orderedItems.filter { item in
            item.displayName.localizedCaseInsensitiveContains(query)
                || item.subtitle.localizedCaseInsensitiveContains(query)
                || (item.previewText?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedItems: [ShelfItem] { filteredItems.filter { selection.ids.contains($0.id) } }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard contentActive, event.window is IslandPanel else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if modifiers == .command, event.keyCode == 3 { searchFocused = true; return nil }
            guard !(event.window?.firstResponder is NSTextView) else { return event }
            if modifiers == .command {
                switch event.keyCode {
                case 0: selection.selectAll(filteredItems.map(\.id))
                case 8: shelf.copy(selectedItems)
                case 9: _ = shelf.paste()
                case 6:
                    guard shelf.pendingRemoval != nil else { return event }
                    shelf.undoRemoval()
                default: return event
                }
                return nil
            }
            guard modifiers.isEmpty || modifiers == .shift else { return event }
            switch event.keyCode {
            case 123, 124, 125, 126:
                let step = event.keyCode == 125 || event.keyCode == 126 ? gridColumns : 1
                selection.move(event.keyCode == 123 || event.keyCode == 126 ? -step : step,
                               in: filteredItems.map(\.id), extending: modifiers == .shift)
            case 49:
                if let item = selectedItems.first { shelf.quickLook(item) }
            case 36:
                if let item = selectedItems.first { shelf.open(item) }
            case 51, 117: shelf.requestRemoval(selectedItems)
            case 53:
                if !selection.ids.isEmpty { selection.clear() } else { appState.dismiss() }
            default: return event
            }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

private struct ShelfDropTargetStyle: ViewModifier {
    let isTargeted: Bool

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.04)))
            .overlay {
                RoundedRectangle(cornerRadius: 16).stroke(
                    isTargeted ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.08),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: isTargeted ? [6] : []))
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct AirDropDropPane: View {
    @ObservedObject var shelf: ShelfStore
    let selectedItems: [ShelfItem]
    @State private var isTargeted = false

    var body: some View {
        Button {
            if selectedItems.isEmpty { shelf.openAirDropPicker() }
            else { shelf.shareViaAirDrop(items: selectedItems) }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 28))
                    .foregroundStyle(isTargeted ? Color.accentColor : .secondary)

                Text("AirDrop")
                    .font(.system(size: 12, weight: .semibold))

                Text("Drop to share")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(maxHeight: .infinity)
            .modifier(ShelfDropTargetStyle(isTargeted: isTargeted))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("shelf-airdrop")
        .help("Share via AirDrop")
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $isTargeted) { providers in
            shelf.handleAirDropDrop(providers: providers)
        }
    }

}

private struct TrayDropPane: View {
    let items: [ShelfItem]
    let totalCount: Int
    let isFiltering: Bool
    @Binding var searchText: String
    @Binding var selection: ShelfSelection
    var searchFocused: FocusState<Bool>.Binding
    @Binding var gridColumns: Int

    @ObservedObject var shelf: ShelfStore
    @EnvironmentObject private var appState: AppState
    @State private var isTargeted = false
    @State private var confirmClear = false
    @State private var clearCandidates: [ShelfItem] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            if totalCount == 0 {
                VStack(spacing: 12) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.82))

                    Text("Drop files here")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.78))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: ShelfGridLayout.sectionSpacing) {
                    HStack(spacing: 8) {
                        if !selection.ids.isEmpty {
                            Text(L10n.format("%d selected", selectedItems.count))
                                .font(.caption).fixedSize()
                            Button(L10n.text("Copy")) { shelf.copy(selectedItems) }
                            Button(L10n.text("Share...")) { shelf.share(items: selectedItems) }
                            Button(L10n.text("Remove")) { shelf.requestRemoval(selectedItems) }
                                .accessibilityIdentifier("shelf-remove-selected")
                        } else {
                            Text("Shelf")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.72))

                            Text(totalCount == 1 ? L10n.text("1 item") : L10n.format("%d items", totalCount))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.42))
                        }

                        Spacer(minLength: 8)

                        TextField("Search", text: $searchText)
                            .accessibilityIdentifier("shelf-search")
                            .focused(searchFocused)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.86))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .frame(minWidth: 60, idealWidth: 150, maxWidth: 150)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.white.opacity(0.06))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )

                        if selection.ids.isEmpty {
                            Menu("Clear") {
                                Button("Clear Unpinned") {
                                    shelf.requestRemoval(shelf.visibleItems.filter { !$0.isPinned })
                                }
                                .disabled(!shelf.items.contains { !$0.isPinned })

                                Button("Clear All") {
                                    clearCandidates = shelf.visibleItems
                                    confirmClear = true
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.78))
                            .hoverPointer()
                        }
                    }
                    .lineLimit(1)
                    .font(.system(size: 11, weight: .medium))
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .frame(height: ShelfGridLayout.toolbarHeight)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("shelf-toolbar")

                    if items.isEmpty && isFiltering {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.64))
                            Text("No matches")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { geometry in
                            let columns = ShelfGridLayout.columns(for: geometry.size.width - ShelfGridLayout.gridPadding * 2)
                            ScrollViewReader { proxy in
                                StableScrollView(.vertical) {
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ShelfGridLayout.spacing), count: columns),
                                              spacing: ShelfGridLayout.spacing) {
                                        ForEach(items) { item in
                                            TrayItemTile(item: item, isSelected: selection.ids.contains(item.id), batchItems: selectedItems, select: { modifiers in
                                                searchFocused.wrappedValue = false
                                                NSApp.keyWindow?.makeFirstResponder(nil)
                                                selection.select(item.id, in: items.map(\.id), extending: modifiers.contains(.shift), toggling: modifiers.contains(.command))
                                            }, shelf: shelf)
                                                .id(item.id)
                                                .transition(appState.motion.reduced ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                                        }
                                    }
                                    .padding(ShelfGridLayout.gridPadding)
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityIdentifier("shelf-file-scroll")
                                .frame(maxHeight: .infinity)
                                .onChange(of: selection.focusedID) { _, id in
                                    if let id { proxy.scrollTo(id, anchor: .center) }
                                }
                            }
                            .onChange(of: columns, initial: true) { _, count in gridColumns = count }
                        }
                        .frame(maxHeight: ShelfGridLayout.viewportHeight)
                    }
                }
                .padding(ShelfGridLayout.panelPadding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .modifier(ShelfDropTargetStyle(isTargeted: isTargeted))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shelf-tray")
        .alert(L10n.text("Clear Shelf?"), isPresented: $confirmClear) {
            Button(L10n.text("Clear All"), role: .destructive) { shelf.requestRemoval(clearCandidates) }
            Button(L10n.text("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.format("Remove %d items, including %d pinned items? You can undo for 10 seconds. Original files are kept.", clearCandidates.count, clearCandidates.filter(\.isPinned).count))
        }
        .onDrop(of: ShelfStore.acceptedDropTypes, isTargeted: $isTargeted) { providers in
            shelf.handleDrop(providers: providers) { _ in
                appState.presentShelfAfterDrop()
            }
        }
    }

    private var selectedItems: [ShelfItem] { items.filter { selection.ids.contains($0.id) } }
}

private struct ExpandedShelfChip: View {
    let item: ShelfItem
    @ObservedObject private var shelf = ShelfStore.shared

    var body: some View {
        Button {
            shelf.open(item)
        } label: {
            HStack(spacing: 8) {
                ShelfItemArtworkView(item: item, size: 24, cornerRadius: 6)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(width: 164, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .hoverPointer()
        .onDrag {
            shelf.dragProvider(for: item)
        }
        .contextMenu {
            ShelfItemActionsMenu(item: item, shelf: shelf)
        }
        .disabled(shelf.isRemoving(item))
        .allowsHitTesting(!shelf.isRemoving(item))
        .opacity(shelf.isRemoving(item) ? 0.5 : 1)
    }
}

private struct TrayItemTile: View {
    let item: ShelfItem
    let isSelected: Bool
    let batchItems: [ShelfItem]
    let select: (NSEvent.ModifierFlags) -> Void
    @ObservedObject var shelf: ShelfStore
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ShelfItemArtworkView(item: item, size: 42, cornerRadius: 9)

                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: 15, height: 15)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.28))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                        )
                        .offset(x: -34, y: -4)
                }

                if item.isMissing || shelf.removalFailures.contains(item.id) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.yellow.opacity(0.95))
                        .frame(width: 15, height: 15)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.28))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                        )
                        .offset(x: -17, y: -4)
                }

                Button {
                    shelf.requestRemoval([item])
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(width: 15, height: 15)
                        .background(.ultraThinMaterial, in: Circle())
                        .background(
                            Circle()
                                .fill(Color.black.opacity(0.28))
                        )
                        .overlay(
                            Circle()
                                .stroke(Color.white.opacity(0.24), lineWidth: 1)
                        )
                        .shadow(color: .white.opacity(0.08), radius: 6)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .opacity(isHovering || isSelected ? 1 : 0)
                .allowsHitTesting(isHovering || isSelected)
                .accessibilityLabel(L10n.text("Remove"))
            }

            VStack(spacing: 2) {
                Text(item.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .top)

                Text(item.subtitle)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .frame(height: ShelfGridLayout.itemHeight, alignment: .top)
        .background(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.5) : .clear,
                    in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { shelf.open(item) }
        .onTapGesture { select(NSEvent.modifierFlags) }
        .onHover { hovering in
            isHovering = hovering
        }
        .onDrag {
            shelf.dragProvider(for: item)
        }
        .overlay(alignment: .top) {
            if isSelected, batchItems.count > 1 {
                ShelfBatchDragSource(items: batchItems, select: select, open: { shelf.open(item) })
                    .frame(maxWidth: .infinity)
                    .frame(height: ShelfGridLayout.itemHeight)
            }
        }
        .contextMenu {
            if isSelected, batchItems.count > 1 {
                Button(L10n.text("Copy")) { shelf.copy(batchItems) }
                Button(L10n.text("Share...")) { shelf.share(items: batchItems) }
                Button(L10n.text("Remove")) { shelf.requestRemoval(batchItems) }
            } else { ShelfItemActionsMenu(item: item, shelf: shelf) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shelf-item-\(item.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .disabled(shelf.isRemoving(item) || isPendingRemoval)
        .allowsHitTesting(!shelf.isRemoving(item) && !isPendingRemoval)
        .accessibilityHidden(isPendingRemoval)
        .opacity(shelf.isRemoving(item) ? 0.5 : 1)
        .help(shelf.removalFailures.contains(item.id)
              ? L10n.text("Unable to remove this item. Check file access and retry.")
              : item.displayName + "\n" + (item.isFileBacked ? item.ownershipDescription : item.subtitle))
    }

    private var isPendingRemoval: Bool { shelf.pendingRemoval?.itemIDs.contains(item.id) == true }
}

private struct ShelfItemActionsMenu: View {
    let item: ShelfItem
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        Button(item.isPinned ? L10n.text("Unpin") : L10n.text("Pin")) {
            shelf.togglePinned(item)
        }

        if !item.isMissing {
            Button("Open") {
                shelf.open(item)
            }
        }

        if item.canQuickLook {
            Button("Quick Look") {
                shelf.quickLook(item)
            }
        }

        if item.isFileBacked && !item.isMissing {
            Button("Show in Finder") {
                shelf.reveal(item)
            }
            if item.ownership == .reference {
                Button(L10n.text("Save a Copy")) { shelf.saveCopy(item) }
            }
        }
        if item.isFileBacked && item.ownership == .reference {
            Button(L10n.text("Locate Original…")) { shelf.locateFile(item) }
        }

        Divider()

        if !item.isMissing || !item.isFileBacked {
            Button(copyTitle) {
                shelf.copy(item)
            }
        }

        if item.isFileBacked {
            Button("Copy Path") {
                shelf.copyPath(item)
            }
        }

        if !item.isMissing || !item.isFileBacked {
            Divider()

            Button("Share...") {
                shelf.share(items: [item])
            }

            Button("Share via AirDrop") {
                shelf.shareViaAirDrop(items: [item])
            }
        }

        Divider()

        Button("Remove") {
            shelf.requestRemoval([item])
        }
    }

    private var copyTitle: String {
        switch item.kind {
        case .link: return L10n.text("Copy Link")
        case .text: return L10n.text("Copy Text")
        default: return L10n.text("Copy Item")
        }
    }
}

private struct ShelfItemArtworkView: View {
    let item: ShelfItem
    let size: CGFloat
    let cornerRadius: CGFloat

    @State private var previewImage: NSImage?

    var body: some View {
        Group {
            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: item.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(item.isFileBacked ? 0 : 2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: item.id) {
            previewImage = await ShelfThumbnailLoader.thumbnail(for: item, size: size)
        }
    }
}

@MainActor
private enum ShelfThumbnailLoader {
    static func thumbnail(for item: ShelfItem, size: CGFloat) async -> NSImage? {
        guard item.isFileBacked, !item.isMissing, let url = item.resolvedFileURL else {
            return nil
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size * 2, height: size * 2),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail, .lowQualityThumbnail]
        )

        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.nsImage)
            }
        }
    }
}
