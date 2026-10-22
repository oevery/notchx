import AppKit
import Foundation
import Quartz
import UniformTypeIdentifiers

enum ShelfItemKind: String, Codable, Hashable {
    case file
    case folder
    case image
    case link
    case text
}

enum ShelfRetentionOption: Int, CaseIterable, Identifiable {
    case never = 0
    case oneDay = 1
    case oneWeek = 7
    case oneMonth = 30
    case threeMonths = 90

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .never: return L10n.text("Keep forever")
        case .oneDay: return L10n.text("1 day")
        case .oneWeek: return L10n.text("7 days")
        case .oneMonth: return L10n.text("30 days")
        case .threeMonths: return L10n.text("90 days")
        }
    }
}

struct ShelfItem: Identifiable, Codable, Hashable {
    let id: UUID
    let kind: ShelfItemKind
    let displayName: String
    let path: String?
    let bookmarkData: Data?
    let urlString: String?
    let textValue: String?
    let addedAt: Date
    var lastAccessedAt: Date?
    var isPinned: Bool
    let ownership: ShelfFileOwnership

    init(
        id: UUID = UUID(),
        kind: ShelfItemKind,
        displayName: String,
        path: String? = nil,
        bookmarkData: Data? = nil,
        urlString: String? = nil,
        textValue: String? = nil,
        addedAt: Date = Date(),
        lastAccessedAt: Date? = nil,
        isPinned: Bool = false,
        ownership: ShelfFileOwnership = .reference
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.path = path
        self.bookmarkData = bookmarkData
        self.urlString = urlString
        self.textValue = textValue
        self.addedAt = addedAt
        self.lastAccessedAt = lastAccessedAt
        self.isPinned = isPinned
        self.ownership = ownership
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case displayName
        case path
        case bookmarkData
        case urlString
        case textValue
        case addedAt
        case lastAccessedAt
        case isPinned, ownership
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = try container.decode(ShelfItemKind.self, forKey: .kind)
        displayName = try container.decode(String.self, forKey: .displayName)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        bookmarkData = try container.decodeIfPresent(Data.self, forKey: .bookmarkData)
        urlString = try container.decodeIfPresent(String.self, forKey: .urlString)
        textValue = try container.decodeIfPresent(String.self, forKey: .textValue)
        addedAt = try container.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        lastAccessedAt = try container.decodeIfPresent(Date.self, forKey: .lastAccessedAt)
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        ownership = try container.decodeIfPresent(ShelfFileOwnership.self, forKey: .ownership)
            ?? (path.map { path in
                ([ShelfFileStorage.defaultRoot] + ShelfFileStorage.legacyImageRoots)
                    .contains { ShelfFileStorage(root: $0).owns(URL(fileURLWithPath: path)) }
            } == true ? .managedCopy : .reference)
    }

    static func file(from url: URL, ownership: ShelfFileOwnership = .reference) -> ShelfItem {
        let bookmarkData = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let kind = fileKind(for: url)
        return ShelfItem(
            kind: kind,
            displayName: displayName(for: url),
            path: url.path,
            bookmarkData: bookmarkData,
            ownership: ownership
        )
    }

    static func link(_ url: URL) -> ShelfItem {
        ShelfItem(
            kind: .link,
            displayName: linkDisplayName(for: url),
            urlString: url.absoluteString
        )
    }

    static func text(_ value: String) -> ShelfItem {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.components(separatedBy: .newlines).first ?? trimmed
        let title = firstLine.isEmpty ? "Text snippet" : String(firstLine.prefix(72))
        return ShelfItem(kind: .text, displayName: title, textValue: trimmed)
    }

    func replacingFile(with url: URL, ownership: ShelfFileOwnership) -> ShelfItem {
        let file = Self.file(from: url, ownership: ownership)
        return ShelfItem(id: id, kind: file.kind, displayName: file.displayName, path: file.path,
                         bookmarkData: file.bookmarkData, addedAt: addedAt, lastAccessedAt: lastAccessedAt,
                         isPinned: isPinned, ownership: ownership)
    }

    var ownershipDescription: String {
        ownership == .managedCopy ? L10n.text("Saved copy") : L10n.text("Original file reference")
    }

    var dedupeKey: String {
        switch kind {
        case .file, .folder, .image:
            return "\(kind.rawValue):\(resolvedFileURL?.standardizedFileURL.path ?? path ?? displayName)"
        case .link:
            return "link:\(urlString ?? displayName)"
        case .text:
            return "text:\(textValue ?? displayName)"
        }
    }

    var subtitle: String {
        switch kind {
        case .file, .folder, .image:
            if isMissing {
                return L10n.text("Missing")
            }
            guard let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) else {
                return L10n.text("File")
            }
            if kind == .folder || url.hasDirectoryPath {
                return L10n.text("Folder")
            }
            if kind == .image {
                return L10n.text("Image")
            }
            let ext = url.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            return ext.isEmpty ? L10n.text("File") : ext.uppercased()
        case .link:
            guard let url = resolvedURL else { return L10n.text("Link") }
            return url.host(percentEncoded: false) ?? L10n.text("Link")
        case .text:
            let count = textValue?.count ?? 0
            return count == 1 ? L10n.text("1 character") : L10n.format("%d characters", count)
        }
    }

    var previewText: String? {
        switch kind {
        case .file, .folder, .image:
            guard let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) else {
                return nil
            }
            let folder = url.deletingLastPathComponent().lastPathComponent
            return folder.isEmpty ? url.path : folder
        case .link:
            return urlString
        case .text:
            guard let textValue else { return nil }
            let collapsed = textValue.replacingOccurrences(of: "\n", with: " ")
            return String(collapsed.prefix(110))
        }
    }

    var resolvedURL: URL? {
        switch kind {
        case .file, .folder, .image:
            return resolvedFileURL
        case .link:
            guard let urlString else { return nil }
            return URL(string: urlString)
        case .text:
            return nil
        }
    }

    var resolvedFileURL: URL? {
        if let bookmarkData {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }

        if let path {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    var icon: NSImage {
        switch kind {
        case .file, .folder, .image:
            if let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            if kind == .image {
                return Self.symbolImage(systemName: "photo.fill")
            }
            return Self.symbolImage(systemName: "doc.fill")
        case .link:
            return Self.symbolImage(systemName: "link")
        case .text:
            return Self.symbolImage(systemName: "text.alignleft")
        }
    }

    var isFileBacked: Bool {
        switch kind {
        case .file, .folder, .image:
            return true
        case .link, .text:
            return false
        }
    }

    var canQuickLook: Bool {
        isFileBacked && !isMissing
    }

    var isMissing: Bool {
        guard isFileBacked else { return false }
        guard let url = resolvedFileURL ?? path.map({ URL(fileURLWithPath: $0) }) else {
            return true
        }
        return !FileManager.default.fileExists(atPath: url.path)
    }

    private static func fileKind(for url: URL) -> ShelfItemKind {
        if url.hasDirectoryPath {
            return .folder
        }

        if let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentTypeKey]) {
            if values.isDirectory == true {
                return .folder
            }
            if values.contentType?.conforms(to: .image) == true {
                return .image
            }
        }

        if let type = UTType(filenameExtension: url.pathExtension),
           type.conforms(to: .image) {
            return .image
        }

        return .file
    }

    private static func displayName(for url: URL) -> String {
        if let localizedName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localizedName.isEmpty {
            return localizedName
        }
        return url.lastPathComponent
    }

    private static func linkDisplayName(for url: URL) -> String {
        if let host = url.host(percentEncoded: false), !host.isEmpty {
            let suffix = url.path == "/" ? "" : url.path
            return host + suffix
        }
        return url.absoluteString
    }

    private static func symbolImage(systemName: String) -> NSImage {
        NSImage(systemSymbolName: systemName, accessibilityDescription: nil) ?? NSImage()
    }
}

/// Provider callbacks can arrive after a drop is cancelled. Keep their progress and
/// cancellation gate independent of the store's actor so they cannot create files late.
private final class ShelfDropSession: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var progresses: [Progress] = []
    private var cancellations: [() -> Void] = []
    private var createdFiles: [URL] = []

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active
    }

    func track(_ progress: Progress) {
        lock.lock()
        if active {
            progresses.append(progress)
            lock.unlock()
        } else {
            lock.unlock()
            progress.cancel()
        }
    }

    func onCancel(_ action: @escaping () -> Void) {
        lock.lock()
        if active {
            cancellations.append(action)
            lock.unlock()
        } else {
            lock.unlock()
            action()
        }
    }

    func withActive<T>(_ action: () -> T?) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard active else { return nil }
        return action()
    }

    func withCreatedFile(_ action: () -> URL?) -> URL? {
        lock.lock()
        guard active else { lock.unlock(); return nil }
        lock.unlock()
        let result = action()
        lock.lock()
        guard active else {
            lock.unlock()
            if let result {
                try? FileManager.default.removeItem(at: result)
                try? FileManager.default.removeItem(at: result.deletingLastPathComponent())
            }
            return nil
        }
        if let result {
            createdFiles.append(result)
            // Promised drops own this newly created UUID bucket as well as its file.
            createdFiles.append(result.deletingLastPathComponent())
        }
        lock.unlock()
        return result
    }

    func trackCreatedFile(_ url: URL) {
        lock.lock()
        if active {
            createdFiles.append(url)
            lock.unlock()
        } else {
            lock.unlock()
            try? FileManager.default.removeItem(at: url)
        }
    }

    func commitCreatedFiles() {
        lock.lock()
        createdFiles.removeAll()
        lock.unlock()
    }

    func discardCreatedFiles() {
        lock.lock()
        let discarded = createdFiles
        createdFiles.removeAll()
        lock.unlock()
        discarded.forEach { try? FileManager.default.removeItem(at: $0) }
    }

    func cancel() {
        lock.lock()
        active = false
        let pending = progresses
        progresses.removeAll()
        let actions = cancellations
        cancellations.removeAll()
        let abandonedFiles = createdFiles
        createdFiles.removeAll()
        lock.unlock()
        actions.forEach { $0() }
        pending.forEach { $0.cancel() }
        abandonedFiles.forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

/// Resumes an async provider wait exactly once, even if cancellation wins the race.
private final class ShelfDropRequest<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value?, Never>?

    init(_ continuation: CheckedContinuation<Value?, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: Value?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}

@MainActor
final class ShelfStore: ObservableObject {
    static let shared = ShelfStore()

    static let acceptedDropTypes: [UTType] = [
        .fileURL,
        .data,
        .url,
        .image,
        .utf8PlainText,
        .plainText,
        .text
    ]

    @Published private(set) var importResults: [ShelfImportResult] = []
    @Published private(set) var operationMessage = ""
    @Published private(set) var items: [ShelfItem]
    @Published private(set) var removingItemIDs: Set<UUID> = []
    @Published private(set) var removalFailures: Set<UUID> = []
    @Published private(set) var pendingRemoval: ShelfPendingRemoval?
    @Published private(set) var lastAddedItemID: UUID?
    private var removalUndoTask: Task<Void, Never>?
    private let pendingRemovalKey = "module.shelf.pendingRemoval"
    @Published private var activeRemovalID: UUID?
    private enum RemovalReason { case explicit, unpinned, expired }
    private struct RemovalRequest {
        let item: ShelfItem
        let reason: RemovalReason
        let generation: UUID
    }
    private var removalQueue: [RemovalRequest] = []
    private var removalTask: Task<Void, Never>?
    @Published var retentionDays: Int {
        didSet {
            preferences.set(retentionDays, forKey: retentionKey)
            pruneExpiredItems()
        }
    }

    private let preferences: UserDefaults
    private let fileStorage: ShelfFileStorage
    private let appState: AppState
    private let quickLookController: ShelfQuickLookController
    private var retryProviders: [UUID: NSItemProvider] = [:]
    private var transferTasks: [UUID: Task<Void, Never>] = [:]
    private let storageKey = "module.shelf.items"
    private let retentionKey = "module.shelf.retentionDays"
    private var isEnabled = false
    private var lifecycleGeneration = UUID()
    private var dropTasks: [UUID: Task<Void, Never>] = [:]
    private var dropSessions: [UUID: ShelfDropSession] = [:]
    private(set) var activeOpenPanel: NSOpenPanel?
    private var panelHandoff: IslandPresentationHandoff?
    private var sharingSessions: [UUID: ShelfSharingSession] = [:]
    var activeSharingPicker: NSSharingServicePicker? { sharingSessions.values.compactMap(\.picker).first }
    private let exports: ShelfExportCoordinator

    init(preferences: UserDefaults = .standard, managedRoot: URL = ShelfFileStorage.defaultRoot,
         fileOperations: ShelfFileOperations = .live, exports: ShelfExportCoordinator? = nil, appState: AppState? = nil) {
        self.preferences = preferences
        self.fileStorage = ShelfFileStorage(root: managedRoot, operations: fileOperations)
        self.appState = appState ?? .shared
        self.quickLookController = ShelfQuickLookController(appState: appState ?? .shared)
        self.exports = exports ?? ShelfExportCoordinator()
        self.retentionDays = preferences.object(forKey: retentionKey) as? Int ?? ShelfRetentionOption.never.rawValue
        if let data = preferences.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            self.items = decoded
        } else {
            self.items = []
        }
        if let data = preferences.data(forKey: pendingRemovalKey) {
            pendingRemoval = try? JSONDecoder().decode(ShelfPendingRemoval.self, from: data)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        lifecycleGeneration = UUID()
        if enabled {
            schedulePendingRemoval()
            pruneExpiredItems()
            let cache = exports.cache
            Task.detached { cache.cleanup() }
        } else {
            // Disabling keeps everything staged for undo. No delayed deletion
            // may unexpectedly resume when the module is enabled again.
            undoRemoval()
            cancelQueuedRemovals()
            cancelImports()
            retryProviders.removeAll()
            transferTasks.values.forEach { $0.cancel() }
            transferTasks.removeAll()
            cancelFileSelection()
            Array(sharingSessions.values).forEach { $0.cancel() }
            quickLookController.close()
        }
    }

    var isEmpty: Bool {
        visibleItems.isEmpty
    }

    var visibleItems: [ShelfItem] {
        items.filter { !(pendingRemoval?.itemIDs.contains($0.id) ?? false) }
    }

    /// Keep model and files intact during the undo window, including across
    /// process restarts. Expiry uses the existing ownership-safe removal queue.
    func requestRemoval(_ candidates: [ShelfItem], now: Date = Date()) {
        guard isEnabled else { return }
        let requested = Set(candidates.map(\.id))
        let ids = Set(items.filter { requested.contains($0.id) && !removingItemIDs.contains($0.id) }.map(\.id))
        guard !ids.isEmpty else { return }
        let previousIDs = pendingRemoval?.itemIDs ?? []
        let newPins = Set(items.filter { ids.contains($0.id) && !previousIDs.contains($0.id) && $0.isPinned }.map(\.id))
        pendingRemoval = ShelfPendingRemoval(itemIDs: previousIDs.union(ids),
                                            pinnedIDs: (pendingRemoval?.pinnedIDs ?? []).union(newPins),
                                            deadline: now.addingTimeInterval(10))
        persistPendingRemoval()
        schedulePendingRemoval()
    }

    func undoRemoval() {
        removalUndoTask?.cancel()
        removalUndoTask = nil
        pendingRemoval = nil
        persistPendingRemoval()
    }

    @discardableResult
    func commitPendingRemoval(now: Date = Date()) -> Task<Void, Never>? {
        guard isEnabled, let pendingRemoval, now >= pendingRemoval.deadline else { return nil }
        let candidates = items.filter { pendingRemoval.itemIDs.contains($0.id) && $0.isPinned == pendingRemoval.pinnedIDs.contains($0.id) }
        undoRemoval()
        return enqueueRemovals(candidates, reason: .explicit)
    }

    private func persistPendingRemoval() {
        if let pendingRemoval, let data = try? JSONEncoder().encode(pendingRemoval) {
            preferences.set(data, forKey: pendingRemovalKey)
        } else { preferences.removeObject(forKey: pendingRemovalKey) }
    }

    private func schedulePendingRemoval() {
        removalUndoTask?.cancel()
        guard let pendingRemoval else { return }
        if pendingRemoval.deadline <= Date() { commitPendingRemoval(); return }
        let deadline = pendingRemoval.deadline
        removalUndoTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.commitPendingRemoval()
            if self?.pendingRemoval != nil { self?.schedulePendingRemoval() }
        }
    }

    func handleDrop(providers: [NSItemProvider], completion: (@MainActor (_ addedCount: Int) -> Void)? = nil) -> Bool {
        guard isEnabled, !providers.isEmpty,
              !providers.contains(where: { $0.registeredTypeIdentifiers.contains(ShelfDragOrigin.typeIdentifier) }) else { return false }
        beginDrop(providers: providers, forSharing: false, completion: completion)
        return true
    }

    var isImporting: Bool { !dropTasks.isEmpty }

    func cancelImports() {
        dropSessions.values.forEach { $0.cancel() }
        dropSessions.removeAll()
        dropTasks.values.forEach { $0.cancel() }
        dropTasks.removeAll()
        for index in importResults.indices where importResults[index].status == .waiting || importResults[index].status == .importing {
            importResults[index].status = .cancelled
        }
    }

    func canRetryImport(_ result: ShelfImportResult) -> Bool {
        isEnabled && (result.status == .failed || result.status == .cancelled) && retryProviders[result.id] != nil
    }

    func retryImport(_ result: ShelfImportResult) {
        guard canRetryImport(result), let provider = retryProviders.removeValue(forKey: result.id) else { return }
        // Retry is an explicit action on an existing result, not a new drop
        // back into Shelf. Keep it independent of outgoing-drag rejection.
        beginDrop(providers: [provider], forSharing: false)
    }

    func clearImportResults() {
        guard !isImporting else { return }
        importResults.removeAll()
        retryProviders.removeAll()
    }

    @discardableResult
    func add(_ incomingItems: [ShelfItem]) -> Int {
        guard isEnabled, !incomingItems.isEmpty else { return 0 }

        var merged = items
        var existingKeys = Set(merged.map(\.dedupeKey))
        var addedCount = 0

        let reservedPaths = Set(items.filter { removingItemIDs.contains($0.id) }.compactMap(\.path)
            .map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        for item in incomingItems {
            let conflictsWithRemoval = item.path.map { path in
                let incoming = URL(fileURLWithPath: path).standardizedFileURL.path
                return reservedPaths.contains { incoming == $0 || incoming.hasPrefix($0 + "/") }
            } ?? false
            guard !removingItemIDs.contains(item.id), !conflictsWithRemoval else { continue }
            let key = item.dedupeKey
            guard !existingKeys.contains(key) else { continue }
            merged.append(item)
            lastAddedItemID = item.id
            existingKeys.insert(key)
            addedCount += 1
        }

        guard addedCount > 0 else { return 0 }
        items = merged
        pruneExpiredItems()
        persist()
        return addedCount
    }

    /// Reference entries disappear immediately; owned files remain visible until
    /// their background deletion succeeds, so failures can be retried safely.
    @discardableResult
    func remove(_ item: ShelfItem) -> Task<Void, Never>? {
        guard let current = items.first(where: { $0.id == item.id }) else { return nil }
        return enqueueRemovals([current], reason: .explicit)
    }

    @discardableResult
    func clear() -> Task<Void, Never>? { enqueueRemovals(items, reason: .explicit) }

    @discardableResult
    func clearUnpinned() -> Task<Void, Never>? {
        enqueueRemovals(items.filter { !$0.isPinned }, reason: .unpinned)
    }

    @discardableResult
    func retryFailedRemovals() -> Task<Void, Never>? {
        enqueueRemovals(items.filter { removalFailures.contains($0.id) }, reason: .explicit)
    }

    func isRemoving(_ item: ShelfItem) -> Bool { activeRemovalID == item.id }

    func togglePinned(_ item: ShelfItem) {
        guard !isRemoving(item) else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isPinned.toggle()
        items[index].lastAccessedAt = Date()
        persist()
    }

    func open(_ item: ShelfItem) {
        switch item.kind {
        case .file, .folder, .image:
            withResolvedFileURL(for: item) { url in
                self.appState.openExternalURL(url, for: .shelf)
            }
        case .link:
            if let url = item.resolvedURL {
                appState.openExternalURL(url, for: .shelf)
                touch(item)
            }
        case .text:
            copy(item)
        }
    }

    func reveal(_ item: ShelfItem) {
        guard item.isFileBacked else { return }
        withResolvedFileURL(for: item) { url in
            guard let session = self.appState.beginPresentationHandoff(.external, for: .shelf) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
            self.appState.finishPresentationHandoff(session, outcome: .completed)
        }
    }

    func quickLook(_ item: ShelfItem) {
        guard item.canQuickLook else {
            NSSound.beep()
            return
        }
        withResolvedFileURL(for: item) { url in
            self.quickLookController.preview(url)
        }
    }

    func copy(_ item: ShelfItem) {
        if item.isFileBacked {
            performExport([item]) { [weak self] payload, export in
                guard let url = payload.first as? URL else { return }
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.writeObjects([url as NSURL]) {
                    self?.exports.keepOnClipboard(export)
                }
            }
        } else if let value = item.urlString ?? item.textValue {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            touch(item)
        }
    }

    func copy(_ candidates: [ShelfItem], to pasteboard: NSPasteboard = .general) {
        guard !candidates.isEmpty else { return }
        performExport(candidates) { [weak self] payload, export in
            let writers: [NSPasteboardWriting] = payload.compactMap { value in
                if let url = value as? URL { return url as NSURL }
                if let text = value as? String { return text as NSString }
                return nil
            }
            guard !writers.isEmpty else { export.finish(); return }
            pasteboard.clearContents()
            if pasteboard.writeObjects(writers) { self?.exports.keepOnClipboard(export) }
            else { export.finish() }
        }
    }

    @discardableResult
    func paste(from pasteboard: NSPasteboard = .general, completion: (@MainActor (Int) -> Void)? = nil) -> Bool {
        let providers = (pasteboard.pasteboardItems ?? []).compactMap { entry -> NSItemProvider? in
            let types = entry.types.filter { identifier in
                guard let type = UTType(identifier.rawValue) else { return false }
                return Self.acceptedDropTypes.contains { type.conforms(to: $0) }
            }
            guard !types.isEmpty else { return nil }
            let provider = NSItemProvider()
            for type in types {
                // Let the existing importer choose its representation before
                // asking the clipboard producer to materialize any bytes.
                let readData: @MainActor @Sendable () -> Data? = { entry.data(forType: type) }
                provider.registerDataRepresentation(forTypeIdentifier: type.rawValue, visibility: .all) { completion in
                    // AppKit objects stay on their owning actor; the provider
                    // receives only the selected representation's Data.
                    Task { @MainActor in completion(readData(), nil) }
                    return nil
                }
            }
            return provider
        }
        return handleDrop(providers: providers, completion: completion)
    }

    func copyPath(_ item: ShelfItem) {
        guard item.isFileBacked,
              let path = item.resolvedFileURL?.path ?? item.path else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
        touch(item)
    }

    func dragProvider(for item: ShelfItem) -> NSItemProvider {
        if item.isFileBacked, let source = item.resolvedFileURL {
            refreshReferenceBookmark(item, url: source)
            let generation = lifecycleGeneration
            let provider = NSItemProvider()
            let export = exports.makeSession()
            provider.suggestedName = item.displayName
            let type = item.kind == .folder ? UTType.folder : (UTType(filenameExtension: source.pathExtension) ?? .data)
            provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { [weak self] completion in
                let progress = Progress(totalUnitCount: 1)
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        guard !progress.isCancelled else { throw CocoaError(.userCancelled) }
                        let exported = try export.copy(source)
                        guard !progress.isCancelled else {
                            export.discard(exported)
                            throw CocoaError(.userCancelled)
                        }
                        export.deliver()
                        progress.completedUnitCount = 1
                        completion(exported, false, nil)
                    } catch {
                        if !progress.isCancelled {
                            Task { @MainActor [weak self] in
                                guard let self, self.isEnabled, self.lifecycleGeneration == generation else { return }
                                self.operationMessage = L10n.text("Unable to export. Check the source files and available space.")
                            }
                        }
                        completion(nil, false, error)
                    }
                }
                return progress
            }
            return ShelfDragOrigin.mark(provider)
        }
        if let url = item.resolvedURL { return ShelfDragOrigin.mark(NSItemProvider(object: url as NSURL)) }
        return ShelfDragOrigin.mark(NSItemProvider(object: (item.textValue ?? item.displayName) as NSString))
    }

    @discardableResult
    func saveCopy(_ item: ShelfItem) -> Task<Void, Never>? {
        guard isEnabled, item.isFileBacked, item.ownership == .reference,
              let source = item.resolvedFileURL else { return nil }
        let id = UUID()
        let generation = lifecycleGeneration
        let storage = fileStorage
        operationMessage = L10n.text("Saving a copy…")
        let task = Task { [weak self] in
            defer { self?.transferTasks.removeValue(forKey: id) }
            do {
                let url = try await Task.detached { try storage.copyIn(source) }.value
                guard let self, self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled,
                      let index = self.items.firstIndex(where: { $0.id == item.id && $0.path == item.path }) else {
                    storage.removeOwned(url)
                    return
                }
                self.items[index] = self.items[index].replacingFile(with: url, ownership: .managedCopy)
                self.persist()
                self.operationMessage = L10n.text("Copy saved. The original file is unchanged.")
            } catch {
                guard let self, self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled else { return }
                self.operationMessage = L10n.text("Unable to save a copy. Check the file and available space.")
            }
        }
        transferTasks[id] = task
        return task
    }

    func locateFile(_ item: ShelfItem) {
        guard isEnabled, item.ownership == .reference else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = item.kind == .folder
        panel.canChooseFiles = item.kind != .folder
        presentFileSelection(panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url,
                  let index = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            self.items[index] = item.replacingFile(with: url, ownership: .reference)
            self.persist()
        }
    }

    func handleAirDropDrop(providers: [NSItemProvider]) -> Bool {
        guard isEnabled, !providers.isEmpty else { return false }
        beginDrop(providers: providers, forSharing: true)
        return true
    }

    private func beginDrop(providers: [NSItemProvider], forSharing: Bool,
                           completion: (@MainActor (Int) -> Void)? = nil) {
        let id = UUID()
        let generation = lifecycleGeneration
        let state = appState
        let revision = state.presentationRevision
        let interaction = forSharing ? state.beginControlInteraction(for: .shelf) : nil
        let session = ShelfDropSession()
        let entries = providers.enumerated().map { index, provider in
            ShelfImportResult(id: UUID(), batchID: id,
                              name: provider.suggestedName ?? L10n.format("Item %d", index + 1), status: .waiting)
        }
        if !isImporting, importResults.count > 100 { clearImportResults() }
        importResults.append(contentsOf: entries)
        for (entry, provider) in zip(entries, providers) { retryProviders[entry.id] = provider }
        dropSessions[id] = session
        let storage = fileStorage
        dropTasks[id] = Task { [weak self] in
            defer { if let interaction { state.endControlInteraction(interaction) } }
            guard let self else { return }
            var added = 0
            var sharingItems: [ShelfItem] = []
            defer {
                session.cancel()
                self.dropTasks.removeValue(forKey: id)
                self.dropSessions.removeValue(forKey: id)
                self.objectWillChange.send()
            }
            for (entry, provider) in zip(entries, providers) {
                guard self.isEnabled, self.lifecycleGeneration == generation, session.isActive, !Task.isCancelled else { return }
                self.setImportStatus(entry.id, .importing)
                let item = await Self.extractItem(from: provider, session: session, storage: storage)
                guard self.isEnabled, self.lifecycleGeneration == generation, session.isActive, !Task.isCancelled else { return }
                guard let item else {
                    session.discardCreatedFiles()
                    self.setImportStatus(entry.id, .failed)
                    continue
                }
                if forSharing {
                    sharingItems.append(item)
                    self.setImportStatus(entry.id, .ready)
                } else if self.add([item]) > 0 {
                    session.commitCreatedFiles()
                    added += 1
                    self.setImportStatus(entry.id, .added)
                } else {
                    session.discardCreatedFiles()
                    self.setImportStatus(entry.id, .duplicate)
                }
            }
            if forSharing, let payload = await self.prepareSharingPayload(sharingItems),
               self.isEnabled, self.lifecycleGeneration == generation, !Task.isCancelled {
                if state.presentationRevision == revision {
                    self.shareViaAirDrop(rawItems: payload.items, export: payload.export)
                } else { payload.export.finish() }
            }
            completion?(added)
        }
    }

    private func setImportStatus(_ id: UUID, _ status: ShelfImportStatus) {
        guard let index = importResults.firstIndex(where: { $0.id == id }) else { return }
        importResults[index].status = status
        if status == .added || status == .duplicate { retryProviders.removeValue(forKey: id) }
    }

    func openAirDropPicker() {
        guard isEnabled else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        presentFileSelection(panel) { [weak self] response in
            guard let self else { return }
            guard response == .OK else { return }
            self.shareViaAirDrop(items: panel.urls.map { ShelfItem.file(from: $0) })
        }
    }

    private func presentFileSelection(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        let context = IslandWindowContext(sourceWindow: NSApp.currentEvent?.window, appState: appState)
        guard activeOpenPanel == nil,
              let session = appState.beginPresentationHandoff(.fileSelection, for: .shelf, returnsToSource: true) else { return }
        let generation = lifecycleGeneration
        activeOpenPanel = panel
        panelHandoff = session
        panel.begin { [weak self] response in
            guard let self, self.activeOpenPanel === panel else { return }
            self.activeOpenPanel = nil
            self.panelHandoff = nil
            let valid = self.isEnabled && self.lifecycleGeneration == generation && self.appState.isPresentationHandoffActive(session)
            self.appState.finishPresentationHandoff(session, outcome: valid ? (response == .OK ? .completed : .cancelled) : .failed)
            if valid { completion(response) }
        }
        if let context {
            let minimum = IslandWindowPlacement.minimumFrameSize(for: panel)
            let frame = IslandWindowPlacement.frame(size: panel.frame.size, savedFrame: panel.frame,
                visibleFrame: context.screen.visibleFrame, islandFrame: context.islandFrame, minimumSize: minimum)
            panel.setFrame(frame, display: false)
        }
    }

    private func cancelFileSelection() {
        let panel = activeOpenPanel
        activeOpenPanel = nil
        if let panelHandoff { appState.finishPresentationHandoff(panelHandoff, outcome: .failed) }
        panelHandoff = nil
        panel?.cancel(nil)
    }

    func shareViaAirDrop(items: [ShelfItem]) {
        let state = appState
        performPresentationExport(items) { [weak self] payload, export, interaction in
            defer { state.endControlInteraction(interaction) }
            self?.shareViaAirDrop(rawItems: payload, export: export)
        }
    }

    func share(items: [ShelfItem], from sourceView: NSView? = nil) {
        guard isEnabled, let view = sourceView ?? (NSApp.currentEvent?.window as? IslandPanel)?.contentView
            ?? NSApp.windows.first(where: { $0 is IslandPanel && $0.isVisible })?.contentView else { return }
        let state = appState
        performPresentationExport(items) { [weak self, weak view] payload, export, interaction in
            guard let self, let view, view.window?.isVisible == true else {
                state.endControlInteraction(interaction)
                export.finish()
                return
            }
            let picker = NSSharingServicePicker(items: payload)
            let session = self.sharingSession(export: export, interaction: interaction)
            session.picker = picker
            picker.delegate = session
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        }
    }

    private func performPresentationExport(_ items: [ShelfItem], action: @escaping ([Any], ShelfExportSession, IslandInteractionToken) -> Void) {
        let state = appState
        let revision = state.presentationRevision
        let interaction = state.beginControlInteraction(for: .shelf)
        performExport(items, onFailure: { state.endControlInteraction(interaction) }) { payload, export in
            guard state.presentationRevision == revision else {
                state.endControlInteraction(interaction)
                export.finish()
                return
            }
            action(payload, export, interaction)
        }
    }

    private func performExport(_ items: [ShelfItem], onFailure: @escaping () -> Void = {}, action: @escaping ([Any], ShelfExportSession) -> Void) {
        guard isEnabled else { onFailure(); return }
        let id = UUID()
        let generation = lifecycleGeneration
        transferTasks[id] = Task { [weak self] in
            var delivered = false
            defer { if !delivered { onFailure() }; self?.transferTasks.removeValue(forKey: id) }
            guard let self else { return }
            guard let payload = await self.prepareSharingPayload(items), self.isEnabled,
                  self.lifecycleGeneration == generation, !Task.isCancelled else { return }
            action(payload.items, payload.export)
            delivered = true
            items.forEach(self.touch)
        }
    }

    private func prepareSharingPayload(_ items: [ShelfItem]) async -> (items: [Any], export: ShelfExportSession)? {
        var payload: [Any] = []
        let export = exports.makeSession()
        operationMessage = L10n.text("Preparing export…")
        do {
            for item in items {
                try Task.checkCancellation()
                if item.isFileBacked {
                    guard let source = item.resolvedFileURL else { throw ShelfFileError.missingSource }
                    refreshReferenceBookmark(item, url: source)
                    let exported = try await withTaskCancellationHandler {
                        try await Task.detached { try export.copy(source) }.value
                    } onCancel: { export.finish() }
                    try Task.checkCancellation()
                    payload.append(exported)
                } else if let url = item.resolvedURL { payload.append(url) }
                else if let text = item.textValue { payload.append(text) }
            }
            operationMessage = ""
            return payload.isEmpty ? nil : (payload, export)
        } catch {
            export.finish()
            if isEnabled, !Task.isCancelled { operationMessage = L10n.text("Unable to export. Check the source files and available space.") }
            return nil
        }
    }

    private func persist() {
        if let encoded = try? JSONEncoder().encode(items) {
            preferences.set(encoded, forKey: storageKey)
        }
    }

    private func refreshReferenceBookmark(_ item: ShelfItem, url: URL) {
        guard item.ownership == .reference, let data = item.bookmarkData else { return }
        var stale = false
        _ = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
                     relativeTo: nil, bookmarkDataIsStale: &stale)
        guard stale || item.path != url.path else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let updated = item.replacingFile(with: url, ownership: .reference)
        guard updated.bookmarkData != nil, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = updated
        persist()
    }

    private func withResolvedFileURL(for item: ShelfItem, _ action: (URL) -> Void) {
        guard let url = item.resolvedFileURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSSound.beep()
            return
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        refreshReferenceBookmark(item, url: url)
        action(url)
        if didAccess {
            url.stopAccessingSecurityScopedResource()
        }
        touch(item)
    }

    private func touch(_ item: ShelfItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].lastAccessedAt = Date()
        persist()
    }

    private func pruneExpiredItems() {
        guard isEnabled, retentionDays > 0 else { return }
        let cutoff = Date().addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))
        enqueueRemovals(visibleItems.filter { !$0.isPinned && $0.addedAt < cutoff && !removalFailures.contains($0.id) }, reason: .expired)
    }

    @discardableResult
    private func enqueueRemovals(_ candidates: [ShelfItem], reason: RemovalReason) -> Task<Void, Never>? {
        guard isEnabled else { return nil }
        var references: Set<UUID> = []
        for item in candidates where !removingItemIDs.contains(item.id) {
            removalFailures.remove(item.id)
            if item.ownership != .managedCopy || item.path == nil {
                references.insert(item.id)
            } else {
                removingItemIDs.insert(item.id)
                removalQueue.append(RemovalRequest(item: item, reason: reason, generation: lifecycleGeneration))
            }
        }
        if !references.isEmpty {
            items.removeAll { references.contains($0.id) }
            persist()
        }
        guard !removalQueue.isEmpty else { return removalTask }
        if removalTask == nil {
            removalTask = Task { [weak self] in
                guard let self else { return }
                await self.processRemovals()
            }
        }
        return removalTask
    }

    private func cancelQueuedRemovals() {
        for request in removalQueue { removingItemIDs.remove(request.item.id) }
        removalQueue.removeAll()
    }

    private func processRemovals() async {
        defer { activeRemovalID = nil; removalTask = nil }
        while !removalQueue.isEmpty {
            guard !Task.isCancelled else { cancelQueuedRemovals(); return }
            let request = removalQueue.removeFirst()
            let id = request.item.id
            guard isEnabled, request.generation == lifecycleGeneration,
                  let current = items.first(where: { $0.id == id }),
                  let path = current.path, current.path == request.item.path, current.ownership == request.item.ownership,
                  current.isPinned == request.item.isPinned else {
                removingItemIDs.remove(id)
                continue
            }
            if request.reason == .expired {
                let cutoff = Date().addingTimeInterval(TimeInterval(-retentionDays * 24 * 60 * 60))
                guard retentionDays > 0, !current.isPinned, current.addedAt < cutoff else {
                    removingItemIDs.remove(id)
                    continue
                }
            }
            activeRemovalID = id
            let stores = [fileStorage] + ShelfFileStorage.legacyImageRoots.map {
                ShelfFileStorage(root: $0, operations: fileStorage.operations)
            }
            let success = await Task.detached(priority: .utility) {
                let url = URL(fileURLWithPath: path)
                // Never delete a reference, another application's storage, or a
                // path escaping the owned root through a parent symlink.
                guard let owner = stores.first(where: { $0.owns(url) }) else { return true }
                return owner.removeOwned(url)
            }.value
            // An in-flight filesystem delete cannot be undone. Reconcile its
            // real result even after disable; only queued work is cancelled.
            if let index = items.firstIndex(where: { $0.id == id && $0.path == current.path && $0.ownership == current.ownership }) {
                if success {
                    items.remove(at: index)
                    removalFailures.remove(id)
                    persist()
                } else { removalFailures.insert(id) }
            }
            activeRemovalID = nil
            removingItemIDs.remove(id)
        }
    }

    private func sharingSession(export: ShelfExportSession, interaction: IslandInteractionToken? = nil, opensWindow: Bool = false) -> ShelfSharingSession {
        let id = UUID()
        let state = appState
        var handoff = opensWindow ? state.beginPresentationHandoff(.window, for: .shelf) : nil
        let session = ShelfSharingSession(export: export, onServiceChosen: {
            if let interaction { state.endControlInteraction(interaction) }
            if handoff == nil { handoff = state.beginPresentationHandoff(.window, for: .shelf) }
        }) { [weak self] in
            if let interaction { state.endControlInteraction(interaction) }
            if let handoff { state.finishPresentationHandoff(handoff, outcome: .cancelled) }
            self?.sharingSessions.removeValue(forKey: id)
        }
        sharingSessions[id] = session
        return session
    }

    private func shareViaAirDrop(rawItems: [Any], export: ShelfExportSession) {
        guard !rawItems.isEmpty,
              let service = NSSharingService(named: .sendViaAirDrop),
              service.canPerform(withItems: rawItems) else {
            NSSound.beep()
            return
        }

        let session = sharingSession(export: export, opensWindow: true)
        session.service = service
        service.delegate = session
        service.perform(withItems: rawItems)
    }

    private static func extractItem(from provider: NSItemProvider, session: ShelfDropSession, storage: ShelfFileStorage) async -> ShelfItem? {

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadURL(from: provider, type: .fileURL, session: session),
           url.isFileURL {
            return await importFileURL(url, session: session, storage: storage)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(from: provider, type: .url, session: session) {
            return url.isFileURL ? await importFileURL(url, session: session, storage: storage) : .link(url)
        }

        // Promised-file drag (Finder advertises only the content type, not
        // public.file-url). loadFileRepresentation resolves it to a temp URL
        // with the original filename, which we copy into shelf storage.
        if let imageTypeIdentifier = provider.registeredTypeIdentifiers.first(where: { identifier in
            guard let type = UTType(identifier) else { return false }
            return type.conforms(to: .image)
        }) {
            if let url = await loadPromisedFile(from: provider, typeIdentifier: imageTypeIdentifier, session: session, storage: storage) {
                return .file(from: url, ownership: .managedCopy)
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let data = await loadData(from: provider, type: .image, session: session),
           session.isActive,
           let item = imageItem(from: data, type: .image, suggestedName: provider.suggestedName, storage: storage) {
            if let url = item.resolvedFileURL { session.trackCreatedFile(url) }
            return item
        }

        for type in [UTType.utf8PlainText, .plainText, .text] {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier),
                  let string = await loadString(from: provider, type: type, session: session) else {
                continue
            }

            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            if let url = recognizedURL(from: trimmed) {
                return url.isFileURL ? await importFileURL(url, session: session, storage: storage) : .link(url)
            }

            return .text(trimmed)
        }

        if let identifier = provider.registeredTypeIdentifiers.first(where: {
            guard let type = UTType($0) else { return false }
            return type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url)
        }), let url = await loadPromisedFile(from: provider, typeIdentifier: identifier, session: session, storage: storage) {
            return .file(from: url, ownership: .managedCopy)
        }

        return nil
    }

    private static func imageItem(from data: Data, type: UTType, suggestedName: String? = nil, storage: ShelfFileStorage) -> ShelfItem? {
        let storageURL = storage.root
        guard data.count <= 20 * 1024 * 1024 else {
            return nil
        }

        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true)
            let fileExtension = type.preferredFilenameExtension ?? "png"
            let fileURL = storageURL.appendingPathComponent("\(UUID().uuidString).\(fileExtension)")
            try data.write(to: fileURL, options: [.atomic])
            let trimmedName = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let display: String
            if trimmedName.isEmpty {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
                display = "Image \(formatter.string(from: Date())).\(fileExtension)"
            } else if (trimmedName as NSString).pathExtension.isEmpty {
                display = "\(trimmedName).\(fileExtension)"
            } else {
                display = trimmedName
            }
            return ShelfItem(
                kind: .image,
                displayName: display,
                path: fileURL.path,
                ownership: .managedCopy
            )
        } catch {
            return nil
        }
    }

    private static func importFileURL(_ url: URL, session: ShelfDropSession, storage: ShelfFileStorage) async -> ShelfItem? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let source = url.standardizedFileURL.resolvingSymlinksInPath().path
        let temporary = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp")]
            .contains { source.hasPrefix($0.standardizedFileURL.resolvingSymlinksInPath().path + "/") }
        guard temporary else { return .file(from: url) }
        return await Task.detached {
            session.withCreatedFile { try? storage.copyIn(url) }
                .map { ShelfItem.file(from: $0, ownership: .managedCopy) }
        }.value
    }

    private static func recognizedURL(from string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "http", "https", "mailto", "file":
            return url
        default:
            return nil
        }
    }

    private static func loadURL(from provider: NSItemProvider, type: UTType, session: ShelfDropSession) async -> URL? {
        guard let item = await loadItem(from: provider, typeIdentifier: type.identifier, session: session) else {
            return nil
        }

        if let url = item as? URL {
            return url
        }
        if let url = item as? NSURL {
            return url as URL
        }
        if let data = item as? Data {
            return URL(dataRepresentation: data, relativeTo: nil)
        }
        if let string = item as? String {
            return URL(string: string)
        }
        if let string = item as? NSString {
            return URL(string: string as String)
        }

        return nil
    }

    private static func loadString(from provider: NSItemProvider, type: UTType, session: ShelfDropSession) async -> String? {
        guard let item = await loadItem(from: provider, typeIdentifier: type.identifier, session: session) else {
            return nil
        }

        if let string = item as? String {
            return string
        }
        if let string = item as? NSString {
            return string as String
        }
        if let data = item as? Data {
            return String(data: data, encoding: .utf8)
        }

        return nil
    }

    private static func loadData(from provider: NSItemProvider, type: UTType, session: ShelfDropSession) async -> Data? {
        await withCheckedContinuation { continuation in
            let request = ShelfDropRequest(continuation)
            session.onCancel { request.finish(nil) }
            guard session.isActive else { return }
            let progress = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                request.finish(session.isActive && error == nil ? data : nil)
            }
            session.track(progress)
        }
    }

    /// Copy before the provider's URL expires; cancelled in-flight copies are discarded.
    private static func loadPromisedFile(from provider: NSItemProvider, typeIdentifier: String, session: ShelfDropSession, storage: ShelfFileStorage) async -> URL? {
        // Resolve actor-isolated storage state before entering the provider's callback.
        return await withCheckedContinuation { continuation in
            let request = ShelfDropRequest(continuation)
            session.onCancel { request.finish(nil) }
            guard session.isActive else { return }
            let progress = provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { tempURL, error in
                let result: URL? = session.withCreatedFile {
                    guard let tempURL, error == nil else { return nil }
                    return try? storage.copyIn(tempURL)
                }
                request.finish(result)
            }
            session.track(progress)
        }
    }

    private static func loadItem(from provider: NSItemProvider, typeIdentifier: String, session: ShelfDropSession) async -> NSSecureCoding? {
        await withCheckedContinuation { continuation in
            let request = ShelfDropRequest(continuation)
            session.onCancel { request.finish(nil) }
            guard session.isActive else { return }
            // Unlike representation loading, loadItem has no cancellable Progress.
            // The one-shot request releases our task immediately on cancellation.
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                request.finish(session.isActive && error == nil ? item : nil)
            }
        }
    }

}

@MainActor
final class ShelfQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private let appState: AppState
    private var handoff: IslandPresentationHandoff?

    init(appState: AppState) { self.appState = appState }

    private var previewURLs: [URL] = []
    private var scopedURLs: [URL] = []

    func close() {
        if QLPreviewPanel.sharedPreviewPanelExists() {
            if let panel = QLPreviewPanel.shared(), panel.delegate === self {
                panel.orderOut(nil)
                panel.dataSource = nil
                panel.delegate = nil
            }
        }
        if let handoff { appState.finishPresentationHandoff(handoff, outcome: .cancelled) }
        handoff = nil
        previewURLs.removeAll()
        closeScopedURLs()
    }

    func preview(_ url: URL) {
        let context = IslandWindowContext(sourceWindow: NSApp.currentEvent?.window, appState: appState)
        closeScopedURLs()

        let didAccess = url.startAccessingSecurityScopedResource()
        if didAccess {
            scopedURLs = [url]
        }

        previewURLs = [url]
        guard let panel = QLPreviewPanel.shared() else {
            closeScopedURLs()
            NSSound.beep()
            return
        }
        guard let session = appState.beginPresentationHandoff(.window, for: .shelf, replacing: handoff) else { closeScopedURLs(); return }
        handoff = session
        if let context {
            let frame = IslandWindowPlacement.frame(size: panel.frame.size, savedFrame: panel.frame,
                visibleFrame: context.screen.visibleFrame, islandFrame: context.islandFrame,
                minimumSize: IslandWindowPlacement.minimumFrameSize(for: panel, contentMinimum: NSSize(width: 200, height: 200)))
            panel.setFrame(frame, display: false)
        }

        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated {
            previewURLs.count
        }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated {
            previewURLs.indices.contains(index) ? previewURLs[index] as NSURL : nil
        }
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { close() }
    }

    private func closeScopedURLs() {
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }
}
