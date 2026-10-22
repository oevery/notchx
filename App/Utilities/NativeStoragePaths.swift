import Foundation

/// New writes use the NotchX namespace. Existing data is copied, never moved or
/// removed: persisted Shelf URLs may still refer to their original locations.
/// If copying fails we keep using the legacy directory rather than hide data.
enum NativeStoragePaths {
    static func directory(in root: URL, component: String) -> URL {
        let manager = FileManager.default
        let destination = root.appendingPathComponent("NotchX", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        let legacy = root.appendingPathComponent("SuperIsland", isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        if !manager.fileExists(atPath: destination.path), manager.fileExists(atPath: legacy.path) {
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".migration-" + UUID().uuidString, isDirectory: true)
            do {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: legacy, to: staging)
                try manager.moveItem(at: staging, to: destination)
            } catch {
                try? manager.removeItem(at: staging)
                return legacy
            }
        }
        try? manager.createDirectory(at: destination, withIntermediateDirectories: true)
        return destination
    }
}
