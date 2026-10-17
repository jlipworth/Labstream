#if !os(tvOS)
import Foundation
import PMSKit

/// Ephemeral request authority. A newer request invalidates all earlier presentation tasks,
/// including tasks suspended in orientation; it is independent of the download attempt.
struct OfflinePlaybackPresentationRequest: Equatable, Sendable {
    let generation: UInt64
}

/// Immutable local authority for one admitted attempt/session. No credentials, client, auth
/// restoration or network lookup may be captured. `item` has local resume precedence and rewind
/// applied exactly once. Assets must belong to this attempt, never to a rating-key prefix lookup.
@MainActor
struct OfflinePlaybackLaunch {
    enum Preview {
        case plexBIF(URL?)
        case jellyfinTiles(URL?)
        case embyBIF(URL?)
    }

    let attemptKey: DownloadAttemptKey
    let presentationRequest: OfflinePlaybackPresentationRequest
    let fileURL: URL
    let item: MediaItem
    let backend: DownloadBackendKind
    let posterURL: URL?
    let preview: Preview
    let chapters: [OfflineChapter]
    let chapterImageURLs: [Int: URL]
    let textSubtitles: [OfflineTextSubtitleTrack]
    let events: any OfflinePlaybackEventSink
}

/// Explicit Play Offline fails closed; rejection never requests a remote fallback.
enum OfflinePlaybackLaunchRejection: Error, Equatable, Sendable {
    case staleAttempt
    case deleting
    case nonterminal
    case missingFile
    case unreadableIndex
    case unsupportedIndex
    case supersededPresentation
}

/// Call `beginPresentationRequest` before orientation and `makeLaunch` AFTER orientation.
/// Immediately before returning success, compare request generation, re-resolve the rendered
/// action identity, reject deletion/nonterminal/replacement and recheck the exact local file.
/// Blocked admission with a readable index permits terminal playback; it grants no mutation right.
@MainActor
protocol OfflinePlaybackLaunchFactory {
    func beginPresentationRequest() -> OfflinePlaybackPresentationRequest
    func makeLaunch(for identity: OfflineDownloadRowActionIdentity,
                    request: OfflinePlaybackPresentationRequest,
                    resumeRewindSeconds: Int) async
        -> Result<OfflinePlaybackLaunch, OfflinePlaybackLaunchRejection>
}
#endif
