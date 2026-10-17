import Foundation
import Darwin

/// Narrow scheduling/fault seam around existing store syscalls. Live defaults preserve ordering,
/// locking, bytes and error handling. Hooks must not call the store: they may run under its lock.
struct DownloadStoreFilesystem: Sendable {
    enum Operation: String, Sendable { case stat, read, rename, remove, copy, enumerate }
    var before: @Sendable (Operation, URL) -> Void = { _, _ in }
    var rename: @Sendable (URL, URL) -> Int32 = { Darwin.rename($0.path, $1.path) }
    var remove: @Sendable (URL, FileManager) throws -> Void = { try $1.removeItem(at: $0) }

    func attributes(atPath path: String, using manager: FileManager) throws -> [FileAttributeKey: Any] {
        before(.stat, URL(fileURLWithPath: path))
        return try manager.attributesOfItem(atPath: path)
    }
    func exists(atPath path: String, using manager: FileManager) -> Bool {
        before(.stat, URL(fileURLWithPath: path))
        return manager.fileExists(atPath: path)
    }
    func read(_ url: URL) throws -> Data {
        before(.read, url)
        return try Data(contentsOf: url)
    }
    func removeItem(at url: URL, using manager: FileManager) throws {
        before(.remove, url)
        try remove(url, manager)
    }
    func copyItem(at source: URL, to destination: URL, using manager: FileManager) throws {
        before(.copy, source)
        try manager.copyItem(at: source, to: destination)
    }
    static let live = Self()
}
