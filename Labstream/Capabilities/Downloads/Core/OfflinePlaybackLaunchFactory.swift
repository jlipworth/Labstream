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
    let artworkSource: OfflineArtworkSource?
    let preview: Preview
    let chapters: [OfflineChapter]
    let chapterImageURLs: [Int: URL]
    let textSubtitles: [OfflineTextSubtitleTrack]
    let events: any OfflinePlaybackEventSink

    init(attemptKey: DownloadAttemptKey, presentationRequest: OfflinePlaybackPresentationRequest,
         fileURL: URL, item: MediaItem, backend: DownloadBackendKind, posterURL: URL?,
         artworkSource: OfflineArtworkSource? = nil, preview: Preview, chapters: [OfflineChapter],
         chapterImageURLs: [Int: URL], textSubtitles: [OfflineTextSubtitleTrack],
         events: any OfflinePlaybackEventSink) {
        self.attemptKey = attemptKey
        self.presentationRequest = presentationRequest
        self.fileURL = fileURL
        self.item = item
        self.backend = backend
        self.posterURL = posterURL
        self.artworkSource = artworkSource
        self.preview = preview
        self.chapters = chapters
        self.chapterImageURLs = chapterImageURLs
        self.textSubtitles = textSubtitles
        self.events = events
    }
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

@MainActor
extension OfflinePlaybackLaunchFactory {
    /// Admission and rejected-request orientation cleanup share the same presentation authority.
    /// Restoration is synchronous so a newer request cannot enter between the check and restore.
    func makeLaunchAfterOrientation(
        for identity: OfflineDownloadRowActionIdentity, request: OfflinePlaybackPresentationRequest,
        resumeRewindSeconds: Int, orientation: () async -> Void,
        restoreOrientation: () -> Void, isCurrent: () -> Bool
    ) async -> Result<OfflinePlaybackLaunch, OfflinePlaybackLaunchRejection> {
        await orientation()
        guard isCurrent() else { return .failure(.supersededPresentation) }
        guard !Task.isCancelled else {
            restoreOrientation()
            return .failure(.supersededPresentation)
        }
        let result = await makeLaunch(for: identity, request: request,
                                      resumeRewindSeconds: resumeRewindSeconds)
        guard isCurrent() else { return .failure(.supersededPresentation) }
        if case .failure(.supersededPresentation) = result { return result }
        if Task.isCancelled {
            restoreOrientation()
            return .failure(.supersededPresentation)
        }
        if case .failure = result { restoreOrientation() }
        return result
    }
}
#endif

#if !os(tvOS)
extension OfflinePlaybackLaunch {
    func makeTrickPlayProvider() -> (any TrickPlayThumbnailProviding)? {
        switch preview {
        case .plexBIF(let url): return LocalBIFTrickPlayThumbnailProvider(bifURL: url)
        case .jellyfinTiles(let url): return LocalJellyfinTrickPlayThumbnailProvider(playlistURL: url)
        case .embyBIF(let url):
            let providers = ([LocalBIFTrickPlayThumbnailProvider(bifURL: url),
                LocalEmbyChapterTrickPlayThumbnailProvider(chapters: chapters,
                    imageURLsByChapterIndex: chapterImageURLs)] as [(any TrickPlayThumbnailProviding)?]).compactMap { $0 }
            return providers.isEmpty ? nil : HierarchicalTrickPlayThumbnailProvider(providers)
        }
    }
}
#endif
