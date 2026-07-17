import Foundation

/// Flushes one exact persistence boundary before releasing background URLSession handlers.
/// Every flush outcome releases the handler: failures/timeouts are observable and remain dirty,
/// while withholding the OS callback indefinitely would violate the background-session contract.
enum BackgroundCompletionPersistenceBarrier {
    typealias Flush = @Sendable () async -> DownloadStore.PersistenceFlushResult
    typealias Observe = @Sendable (DownloadStore.PersistenceFlushResult) -> Void
    typealias Release = @MainActor @Sendable (String) -> Void

    @discardableResult
    static func flushThenRelease(
        identifiers: [String],
        flush: Flush,
        observe: Observe = { _ in },
        release: Release
    ) async -> DownloadStore.PersistenceFlushResult {
        let result = await flush()
        observe(result)
        await MainActor.run {
            for identifier in identifiers { release(identifier) }
        }
        return result
    }
}
