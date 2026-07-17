import Darwin
import Foundation
import PMSKit

struct DownloadStaticCheckpointFilesystem: Sendable {
    let exists: @Sendable (URL) -> Bool
    let size: @Sendable (URL) -> Int?
    let durableCopy: @Sendable (URL, URL, URL) throws -> Void

    static let live = Self(
        exists: { FileManager.default.fileExists(atPath: $0.path) },
        size: { DownloadFileStat.logicalSize(
            at: $0, attributesOfItem: FileManager.default.attributesOfItem(atPath:)) },
        durableCopy: { source, destination, temporary in
            try? FileManager.default.removeItem(at: temporary)
            var removeTemporary = true
            defer {
                if removeTemporary { try? FileManager.default.removeItem(at: temporary) }
            }
            try FileManager.default.copyItem(at: source, to: temporary)
            try CredentialArtifactStorage.applyProtectionAndBackupExclusion(
                to: temporary,
                protection: CredentialArtifactStorage.authArtifactProtection)
            let file = Darwin.open(temporary.path, O_RDONLY)
            guard file >= 0 else { throw POSIXError(.EIO) }
            defer { _ = Darwin.close(file) }
            guard Darwin.fcntl(file, F_FULLFSYNC) == 0 else { throw POSIXError(.EIO) }
            guard Darwin.rename(temporary.path, destination.path) == 0 else { throw POSIXError(.EIO) }
            removeTemporary = false
            let directory = Darwin.open(destination.deletingLastPathComponent().path, O_RDONLY)
            guard directory >= 0 else { throw POSIXError(.EIO) }
            defer { _ = Darwin.close(directory) }
            guard Darwin.fsync(directory) == 0 else { throw POSIXError(.EIO) }
        })
}
