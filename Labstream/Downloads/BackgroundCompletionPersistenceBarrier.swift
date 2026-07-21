import Foundation

/// Flushes one exact persistence boundary before releasing background URLSession handlers.
/// Every flush outcome releases the handler: failures/timeouts are observable and remain dirty,
/// while withholding the OS callback indefinitely would violate the background-session contract.
enum BackgroundCompletionPersistenceBarrier {
    typealias Flush = @Sendable () async -> DownloadStore.PersistenceFlushResult
    typealias Observe = @Sendable (DownloadStore.PersistenceFlushResult) -> Void
    @discardableResult
    static func flushThenRelease<ReleaseUnit: Sendable>(
        releases: [ReleaseUnit],
        flush: Flush,
        observe: Observe = { _ in },
        release: @MainActor @Sendable (ReleaseUnit) -> Void
    ) async -> DownloadStore.PersistenceFlushResult {
        let result = await flush()
        observe(result)
        await MainActor.run {
            for unit in releases { release(unit) }
        }
        return result
    }
}
