import Darwin
import Foundation
import PMSKit

/// Explicit same-directory commit protocol for the download index.
///
/// Foundation's opaque `.atomic` write does not expose the write/rename crash boundaries that
/// download durability tests need to exercise. This committer makes those stages explicit while
/// retaining the same single-file JSON format: write a unique sibling temp, sync its contents,
/// atomically rename it over the canonical file, then sync the parent directory entry.
struct DownloadIndexFileCommitter: Sendable {
    enum Stage: String, Sendable, CaseIterable {
        case beforeTempWrite
        case afterTempWrite
        case afterFileSync
        case beforeReplace
        case afterReplace
        case afterDirectorySync
    }

    struct CommitFailure: Error, Sendable, Equatable {
        let stage: Stage
        let errorType: String
        let errnoCode: Int32?
        /// Once replacement occurs, a reported failure is ambiguous to the caller even though
        /// the canonical bytes may already be the new valid snapshot.
        let replacementMayHaveOccurred: Bool
    }

    typealias StageHook = @Sendable (Stage) throws -> Void

    struct DurabilityOperations: Sendable {
        let fullSync: @Sendable (Int32) -> Int32?
        let directorySync: @Sendable (Int32) -> Int32?

        static let live = DurabilityOperations(
            fullSync: { descriptor in
                Darwin.fcntl(descriptor, F_FULLFSYNC) == 0 ? nil : errno
            },
            directorySync: { descriptor in
                Darwin.fsync(descriptor) == 0 ? nil : errno
            }
        )
    }

    private let stageHook: StageHook
    private let durability: DurabilityOperations

    init(
        durability: DurabilityOperations = .live,
        stageHook: @escaping StageHook = { _ in }
    ) {
        self.durability = durability
        self.stageHook = stageHook
    }

    func commit(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let prefix = ".\(destination.lastPathComponent).commit-"
        let temporary = directory.appendingPathComponent(prefix + UUID().uuidString)
        var stage: Stage = .beforeTempWrite
        var replacementMayHaveOccurred = false

        do {
            try stageHook(stage)
            try writeAndSync(data, to: temporary) {
                stage = .afterTempWrite
                try stageHook(stage)
            }
            stage = .afterFileSync
            try stageHook(stage)

            stage = .beforeReplace
            try stageHook(stage)
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw POSIXFailure(code: errno)
            }
            replacementMayHaveOccurred = true

            stage = .afterReplace
            try stageHook(stage)
            try syncDirectory(directory)

            stage = .afterDirectorySync
            try stageHook(stage)
        } catch {
            // Before rename this removes only the unreferenced sibling temp. After rename the temp
            // no longer exists and the valid canonical replacement is deliberately left intact.
            try? FileManager.default.removeItem(at: temporary)
            if let failure = error as? CommitFailure { throw failure }
            let code = (error as? POSIXFailure)?.code
            throw CommitFailure(
                stage: stage,
                errorType: String(reflecting: type(of: error)),
                errnoCode: code,
                replacementMayHaveOccurred: replacementMayHaveOccurred
            )
        }
    }

    /// Startup-only recovery for abandoned temps. A minimum age prevents a second live store or
    /// process from unlinking a sibling commit that is still being written.
    static func cleanupAbandonedTemps(
        for destination: URL,
        olderThan cutoff: Date = Date().addingTimeInterval(-3_600),
        fileManager: FileManager = .default
    ) throws {
        let directory = destination.deletingLastPathComponent()
        let prefix = ".\(destination.lastPathComponent).commit-"
        let children = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: []
        )
        for child in children where child.lastPathComponent.hasPrefix(prefix) {
            let modified = try child.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            guard let modified, modified < cutoff else { continue }
            try fileManager.removeItem(at: child)
        }
    }

    private func writeAndSync(
        _ data: Data,
        to url: URL,
        afterWrite: () throws -> Void
    ) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXFailure(code: errno) }

        var closeRequired = true
        defer {
            if closeRequired { _ = Darwin.close(descriptor) }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, pointer, remaining)
                guard written >= 0 else {
                    if errno == EINTR { continue }
                    throw POSIXFailure(code: errno)
                }
                guard written > 0 else { throw POSIXFailure(code: EIO) }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
        }

        try afterWrite()
        try CredentialArtifactStorage.applyProtectionAndBackupExclusion(
            to: url,
            protection: CredentialArtifactStorage.authArtifactProtection
        )
        if let code = durability.fullSync(descriptor) { throw POSIXFailure(code: code) }
        guard Darwin.close(descriptor) == 0 else { throw POSIXFailure(code: errno) }
        closeRequired = false
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXFailure(code: errno) }
        defer { _ = Darwin.close(descriptor) }
        if let code = durability.directorySync(descriptor) { throw POSIXFailure(code: code) }
    }

    private struct POSIXFailure: Error, Sendable {
        let code: Int32
    }
}
