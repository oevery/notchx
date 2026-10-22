import Foundation

/// Shared by the rendered grid and its keyboard navigation.
enum ShelfGridLayout {
    static let itemHeight: CGFloat = 110
    static let spacing: CGFloat = 12
    static let gridPadding: CGFloat = 6
    static let panelPadding: CGFloat = 14
    static let toolbarHeight: CGFloat = 26
    static let sectionSpacing: CGFloat = 10
    static let feedbackHeight: CGFloat = 28
    static let feedbackSpacing: CGFloat = 8
    static let viewportHeight = itemHeight * 2 + spacing + gridPadding * 2
    static let contentHeight = toolbarHeight + sectionSpacing + viewportHeight
        + panelPadding * 2 + feedbackSpacing + feedbackHeight

    static func columns(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (116 + spacing)))
    }
}

struct ShelfPendingRemoval: Codable {
    let itemIDs: Set<UUID>
    let pinnedIDs: Set<UUID>
    let deadline: Date
}

/// Selection is scoped to the visible search result, in its displayed order.
struct ShelfSelection {
    private(set) var ids: Set<UUID> = []
    private var anchor: UUID?
    private(set) var focusedID: UUID?

    mutating func select(_ id: UUID, in visibleIDs: [UUID], extending: Bool = false, toggling: Bool = false) {
        guard visibleIDs.contains(id) else { return }
        if extending, let anchor, let start = visibleIDs.firstIndex(of: anchor), let end = visibleIDs.firstIndex(of: id) {
            let range = Set(visibleIDs[min(start, end)...max(start, end)])
            ids = toggling ? ids.union(range) : range
        } else if toggling {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        } else { ids = [id]; anchor = id }
        focusedID = id
    }

    mutating func selectAll(_ visibleIDs: [UUID]) {
        ids = Set(visibleIDs)
        anchor = visibleIDs.first
        focusedID = visibleIDs.last
    }

    mutating func move(_ delta: Int, in visibleIDs: [UUID], extending: Bool) {
        guard !visibleIDs.isEmpty else { return }
        let current = focusedID.flatMap { visibleIDs.firstIndex(of: $0) }
        let index = current.map { min(visibleIDs.count - 1, max(0, $0 + delta)) } ?? (delta < 0 ? visibleIDs.count - 1 : 0)
        select(visibleIDs[index], in: visibleIDs, extending: extending)
    }

    mutating func reconcile(_ visibleIDs: [UUID]) {
        ids.formIntersection(visibleIDs)
        if focusedID.map({ !visibleIDs.contains($0) }) ?? true {
            focusedID = visibleIDs.first { ids.contains($0) }
        }
        if anchor.map({ !visibleIDs.contains($0) }) ?? true { anchor = focusedID }
    }

    mutating func clear() { self = ShelfSelection() }
}
