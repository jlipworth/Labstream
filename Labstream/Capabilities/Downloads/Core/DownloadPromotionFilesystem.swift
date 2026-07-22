import Darwin
import Foundation
import PMSKit

struct DownloadPromotionFilesystem: Sendable {
    let exists: @Sendable (URL) -> Bool
    let size: @Sendable (URL) -> Int?
    let fullSyncSource: @Sendable (URL) throws -> Void
    let renameReplacing: @Sendable (URL, URL) throws -> Void
    let syncParentDirectory: @Sendable (URL) throws -> Void

    static let live = Self(
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        size: { DownloadFileStat.logicalSize(
            at: $0, attributesOfItem: FileManager.default.attributesOfItem(atPath:)) },
        fullSyncSource: { source in
            let file = Darwin.open(source.path, O_RDONLY)
            guard file >= 0 else { throw POSIXError(.EIO) }
            defer { _ = Darwin.close(file) }
            guard Darwin.fcntl(file, F_FULLFSYNC) == 0 else { throw POSIXError(.EIO) }
        },
        renameReplacing: { source, destination in
            guard Darwin.rename(source.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        },
        syncParentDirectory: { destination in
            let directory = Darwin.open(
                destination.deletingLastPathComponent().path, O_RDONLY)
            guard directory >= 0 else { throw POSIXError(.EIO) }
            defer { _ = Darwin.close(directory) }
            guard Darwin.fsync(directory) == 0 else { throw POSIXError(.EIO) }
        })
}
