#if !os(tvOS)
import Foundation
import PMSKit

/// A playback generation is independent of attempt identity: reopening the same attempt revokes
/// older observers AND queued/terminal samples, so a delayed old close cannot overwrite a reopen.
struct OfflinePlaybackSessionGeneration: Hashable, Sendable {
    let rawValue: UUID
}

/// Captured position facts, never a resume/seek-derived proof of actual playback.
struct OfflinePlaybackProgressSample: Equatable, Sendable {
    let positionMs: Int
    let durationMs: Int?
}

/// One launch owns one sink and its exact attempt forever; delayed events never look up a new
/// attempt by rating key. All submission/resolution uses P6's bounded exact-key async contract.
/// Keep at most one resolving position commit and one latest pending sample; duplicate samples
/// coalesce. Persistence timeout/failure is explicit failure, never an acknowledged save.
@MainActor
protocol OfflinePlaybackEventSink: AnyObject {
    var attemptKey: DownloadAttemptKey { get }
    var sessionGeneration: OfflinePlaybackSessionGeneration { get }

    /// Position alone cannot promote an unverified download, even when positive at startup.
    func progress(positionMs: Int, durationMs: Int?)
    /// Only current-item, current-session actual playing may verify eligible probe-miss rows.
    /// A persisted `truncatedRepeated` warning is never erased by playback.
    func playbackObserved()
    /// Revoke observer events immediately, but retain this captured terminal sample until its
    /// exact submission resolves or explicit failure is recorded. A newer session supersedes it.
    func close(finalSample: OfflinePlaybackProgressSample)
}
#endif
