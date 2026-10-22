import SwiftUI

struct ShelfImportFeedbackView: View {
    @ObservedObject private var shelf = ShelfStore.shared
    @State private var showHistory = false

    init(shelf: ShelfStore? = nil) {
        _shelf = ObservedObject(wrappedValue: shelf ?? .shared)
    }

    var body: some View {
        HStack(spacing: 10) {
            if shelf.isImporting || !shelf.removingItemIDs.isEmpty { ProgressView().controlSize(.small) }
            Text(summary).font(.caption).lineLimit(1).help(summary)
                .foregroundStyle(shelf.removalFailures.isEmpty ? Color.secondary : .yellow)
            Spacer(minLength: 0)
            if shelf.pendingRemoval != nil {
                Button(L10n.text("Undo")) { shelf.undoRemoval() }
                    .accessibilityIdentifier("shelf-undo")
            }
            if !shelf.removalFailures.isEmpty {
                Button(L10n.text("Retry")) { shelf.retryFailedRemovals() }
            }
            if shelf.isImporting {
                Button(L10n.text("Cancel Import")) { shelf.cancelImports() }
            }
            if !shelf.importResults.isEmpty {
                Button(L10n.text("Import Results")) { showHistory = true }
                    .accessibilityIdentifier("shelf-import-results")
                    .popover(isPresented: $showHistory) { history }
            }
        }
        .controlSize(.small)
        .frame(height: ShelfGridLayout.feedbackHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("shelf-feedback")
        .islandPopoverInteraction(isPresented: $showHistory, module: .shelf)
    }

    private var summary: String {
        if !shelf.removalFailures.isEmpty {
            return L10n.format("Unable to remove %d items. They remain on Shelf.", shelf.removalFailures.count)
        }
        if let pending = shelf.pendingRemoval {
            return L10n.format("%d items removed. Undo is available for 10 seconds.", pending.itemIDs.count)
        }
        if !shelf.removingItemIDs.isEmpty {
            return L10n.format("Removing items: %d", shelf.removingItemIDs.count)
        }
        let failures = shelf.importResults.filter { $0.status == .failed }.count
        if failures > 0 { return L10n.format("%d failed", failures) }
        if !shelf.operationMessage.isEmpty && !shelf.isImporting { return shelf.operationMessage }
        guard !shelf.importResults.isEmpty else { return "" }
        let complete = shelf.importResults.filter { $0.status != .waiting && $0.status != .importing }.count
        return L10n.format("Import: %d of %d processed", complete, shelf.importResults.count)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("Import Results")).font(.headline)
                .accessibilityIdentifier("shelf-import-history-title")
            Text(L10n.text("Completed items are kept when an import is cancelled. Failed items can be retried or dragged in again."))
                .font(.caption).foregroundStyle(.secondary)
            StableScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(shelf.importResults) { result in
                        HStack {
                            Text(result.name).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(statusTitle(result.status)).font(.caption).foregroundStyle(.secondary)
                            if shelf.canRetryImport(result) {
                                Button(L10n.text("Retry")) { shelf.retryImport(result) }
                            }
                        }
                    }
                }
            }
            Button(L10n.text("Clear Import Results")) { shelf.clearImportResults() }
                .disabled(shelf.isImporting)
        }
        .padding(16)
        .frame(width: 420, height: 280)
        .foregroundStyle(.primary)
        .buttonStyle(.bordered)
        // A popover is a separate native presentation. Give its material,
        // text and controls the same appearance as the black island surface.
        .preferredColorScheme(.dark)
    }

    private func statusTitle(_ status: ShelfImportStatus) -> String {
        switch status {
        case .waiting: return L10n.text("Waiting")
        case .importing: return L10n.text("Importing…")
        case .added: return L10n.text("Added")
        case .duplicate: return L10n.text("Already on Shelf")
        case .failed: return L10n.text("Unable to read item")
        case .cancelled: return L10n.text("Cancelled")
        case .ready: return L10n.text("Prepared for sharing")
        }
    }
}
