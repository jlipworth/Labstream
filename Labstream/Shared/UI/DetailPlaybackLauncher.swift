import Foundation
import PMSKit

@MainActor
enum DetailPlaybackLauncher {
    static func itemWithResumeRewind(_ item: MediaItem, resumeRewindSeconds: Int) -> MediaItem {
        guard item.viewOffset != nil, resumeRewindSeconds > 0 else { return item }
        return copy(item, viewOffset: adjustedResumeOffsetMs(item.viewOffset,
                                                            resumeRewindSeconds: resumeRewindSeconds))
    }

    static func metadataItem(ratingKey: String,
                             fallback: MediaItem,
                             trustedDetailSnapshot: MetadataSnapshot? = nil,
                             metadataRepository: MetadataRepository? = nil,
                             context: MediaBrowserPlaybackContext,
                             appModel: AppModel,
                             resumeRewindSeconds: Int) async -> MediaItem {
        if let trustedDetailSnapshot,
           metadataRepository?.mayAuthorizeAction(trustedDetailSnapshot,
                                                   appModel: appModel,
                                                   backend: context.backend,
                                                   itemID: ratingKey)
            ?? trustedDetailSnapshot.mayAuthorizeAction(in: appModel,
                                                        backend: context.backend,
                                                        itemID: ratingKey) {
            return itemWithResumeRewind(trustedDetailSnapshot.item,
                                        resumeRewindSeconds: resumeRewindSeconds)
        }
        let fetched: MediaItem?
        switch context.backend {
        case .plex:
            fetched = nil
        case .jellyfin:
            fetched = try? await JellyfinBrowseService(appModel: appModel).metadata(
                itemId: ratingKey, session: context.session, identity: context.identity)
        case .emby:
            fetched = try? await EmbyBrowseService(appModel: appModel).metadata(
                itemId: ratingKey, session: context.session, identity: context.identity)
        }
        return itemWithResumeRewind(fetched ?? fallback, resumeRewindSeconds: resumeRewindSeconds)
    }

    enum OpenError: Error {
        case unsupportedBackend
        case sessionUnavailable
        case staleSession
    }

    static func context(backend: MediaBackendKind,
                        appModel: AppModel) throws -> MediaBrowserPlaybackContext {
        guard backend != .plex,
              let session = appModel.backendSession(for: backend.downloadBackendKind) else {
            throw backend == .plex ? OpenError.unsupportedBackend : OpenError.sessionUnavailable
        }
        return MediaBrowserPlaybackContext(
            backend: backend,
            session: session,
            authRevision: appModel.authSessionRevision(for: backend),
            identity: appModel.identity)
    }

    static func open(item: MediaItem,
                     backend: MediaBackendKind,
                     appModel: AppModel,
                     mediaIndex: Int = 0,
                     maxVideoBitrateKbps: Int) async throws -> DetailRemotePlaybackOpen {
        let context = try context(backend: backend, appModel: appModel)
        return try await open(item: item,
                              context: context,
                              appModel: appModel,
                              mediaIndex: mediaIndex,
                              maxVideoBitrateKbps: maxVideoBitrateKbps)
    }

    static func open(item: MediaItem,
                     context: MediaBrowserPlaybackContext,
                     appModel: AppModel,
                     mediaIndex: Int = 0,
                     maxVideoBitrateKbps: Int) async throws -> DetailRemotePlaybackOpen {
        let selection = MediaBrowserPlaybackPreferencePolicy.initialSelection(for: item,
                                                                               mediaIndex: mediaIndex)
        let mediaSourceID = MediaBrowserPlaybackPreferencePolicy.mediaSourceID(for: item,
                                                                               mediaIndex: mediaIndex)
        let result: MediaBrowserPlaybackOpenResult
        switch context.backend {
        case .jellyfin:
            result = try await JellyfinBrowseService(appModel: appModel)
                .playbackOpen(item: item,
                              session: context.session,
                              identity: context.identity,
                              maxVideoBitrateKbps: maxVideoBitrateKbps,
                              mediaSourceId: mediaSourceID,
                              audioStreamIndex: selection.audioStreamIndex,
                              subtitleStreamIndex: selection.subtitleStreamIndex)
        case .emby:
            // The initial PlaybackInfo must carry explicit stream selection. Omitting the
            // subtitle sentinel lets Emby's server-side user profile burn in a default subtitle
            // while the app picker still shows Off.
            result = try await EmbyBrowseService(appModel: appModel)
                .playbackOpen(item: item,
                              session: context.session,
                              identity: context.identity,
                              maxVideoBitrateKbps: maxVideoBitrateKbps,
                              mediaSourceId: mediaSourceID,
                              audioStreamIndex: selection.audioStreamIndex,
                              subtitleStreamIndex: selection.subtitleStreamIndex)
        case .plex:
            throw OpenError.unsupportedBackend
        }
        return DetailRemotePlaybackOpen(
            playback: MediaBrowserRemotePlayback(context: context,
                                                  result: result,
                                                  mediaIndex: mediaIndex),
            playMethod: result.playMethod.rawValue)
    }

    static func playbackController(remote: MediaBrowserRemotePlayback,
                                   item: MediaItem,
                                   appModel: AppModel,
                                   maxVideoBitrateKbps: Int,
                                   qualityDefaultsKey: String) -> PlaybackController {
        let progressBackend: MediaBrowserPlaybackProgressSession.Backend = switch remote.backend {
        case .jellyfin: .jellyfin
        case .emby: .emby
        case .plex: preconditionFailure("Plex cannot produce MediaBrowser remote playback")
        }
        let progressSession = mediaBrowserProgressSession(
            backend: progressBackend,
            item: item,
            context: remote.context,
            mediaSourceId: remote.mediaSourceId,
            playSessionId: remote.playSessionId,
            playMethod: remote.playMethod)
        let session = MediaBrowserPlaybackSession(
            streamURL: remote.url,
            backendLabel: remote.backend.displayName,
            httpHeaders: remote.headers,
            playSessionID: remote.playSessionId,
            sourceMetadata: remote.sourceMetadata,
            playMethod: remote.playMethod,
            transcodeReasons: remote.transcodeReasons,
            progressSession: progressSession,
            onStop: {
                stopActiveEncoding(remote: remote, appModel: appModel)
            },
            reopener: { request in
                try await reopenStream(context: remote.context,
                                       item: item,
                                       appModel: appModel,
                                       mediaSourceId: remote.mediaSourceId,
                                       request: request)
            })
        return PlaybackController(
            item: item,
            sessionSource: .mediaBrowser(session),
            identity: remote.context.identity,
            client: appModel.client,
            maxVideoBitrateKbps: maxVideoBitrateKbps,
            qualityDefaultsKey: qualityDefaultsKey,
            mediaIndex: remote.mediaIndex,
            initialAudioStreamIndex: MediaBrowserPlaybackPreferencePolicy
                .initialAudioStreamIndex(for: item, mediaIndex: remote.mediaIndex),
            initialSubtitleStreamIndex: MediaBrowserPlaybackPreferencePolicy
                .preferredSubtitleStreamIndex(for: item, mediaIndex: remote.mediaIndex))
    }

    /// Resolve the race between an async PlaybackInfo response and detail/auth replacement. A
    /// successful stale response may already own an encoder, so rejecting it includes exact-context
    /// cleanup rather than merely dropping the value.
    static func acceptInitialOpen(
        _ opened: DetailRemotePlaybackOpen,
        requestStillCurrent: Bool,
        appModel: AppModel,
        cleanup: @MainActor (MediaBrowserRemotePlayback) async -> Void
    ) async -> Bool {
        guard requestStillCurrent, opened.playback.context.isCurrent(in: appModel) else {
            await cleanup(opened.playback)
            return false
        }
        return true
    }

    static func shouldSurfaceOpenFailure(requestStillCurrent: Bool,
                                         context: MediaBrowserPlaybackContext?,
                                         appModel: AppModel) -> Bool {
        requestStillCurrent && (context?.isCurrent(in: appModel) ?? true)
    }

    static func shouldContinueAfterMetadata(requestStillCurrent: Bool,
                                            context: MediaBrowserPlaybackContext,
                                            appModel: AppModel) -> Bool {
        requestStillCurrent && context.isCurrent(in: appModel)
    }

    private static func reopenStream(context: MediaBrowserPlaybackContext,
                                     item: MediaItem,
                                     appModel: AppModel,
                                     mediaSourceId: String,
                                     request: RemoteStreamReopenRequest) async throws -> RemoteStreamOpenResult {
        let result: MediaBrowserPlaybackOpenResult
        guard context.isCurrent(in: appModel) else { throw OpenError.staleSession }
        switch context.backend {
        case .jellyfin:
            result = try await JellyfinBrowseService(appModel: appModel)
                .playbackOpen(item: item,
                              session: context.session,
                              identity: context.identity,
                              maxVideoBitrateKbps: request.bitrateKbps,
                              resumeOffsetMs: request.offsetMs,
                              mediaSourceId: mediaSourceId,
                              audioStreamIndex: request.audioStreamIndex,
                              subtitleStreamIndex: request.subtitleStreamIndex)
        case .emby:
            result = try await EmbyBrowseService(appModel: appModel)
                .playbackOpen(item: item,
                              session: context.session,
                              identity: context.identity,
                              maxVideoBitrateKbps: request.bitrateKbps,
                              resumeOffsetMs: request.offsetMs,
                              mediaSourceId: mediaSourceId,
                              audioStreamIndex: request.audioStreamIndex,
                              subtitleStreamIndex: request.subtitleStreamIndex)
        case .plex:
            throw OpenError.unsupportedBackend
        }
        let reopened = MediaBrowserRemotePlayback(context: context, result: result)
        guard context.isCurrent(in: appModel) else {
            await stopActiveEncodingNow(remote: reopened, appModel: appModel)
            throw OpenError.staleSession
        }
        return RemoteStreamOpenResult(
            url: reopened.url,
            headers: reopened.headers,
            playSessionId: reopened.playSessionId,
            mediaSourceId: reopened.mediaSourceId,
            sourceMetadata: reopened.sourceMetadata,
            playMethod: reopened.playMethod,
            transcodeReasons: reopened.transcodeReasons,
            onStop: {
                stopActiveEncoding(remote: reopened, appModel: appModel)
            })
    }

    static func stopActiveEncoding(remote: MediaBrowserRemotePlayback,
                                   appModel: AppModel) {
        guard remote.requiresActiveEncodingStop else { return }
        Task { await stopActiveEncodingNow(remote: remote, appModel: appModel) }
    }

    @discardableResult
    static func stopActiveEncodingNow(remote: MediaBrowserRemotePlayback,
                                      appModel: AppModel) async -> Bool {
        guard remote.requiresActiveEncodingStop else { return true }
        switch remote.backend {
        case .jellyfin:
            return await JellyfinBrowseService(appModel: appModel)
                .stopActiveEncoding(playSessionId: remote.playSessionId,
                                    session: remote.context.session,
                                    identity: remote.context.identity)
        case .emby:
            return await EmbyBrowseService(appModel: appModel)
                .stopActiveEncoding(playSessionId: remote.playSessionId,
                                    session: remote.context.session,
                                    identity: remote.context.identity)
        case .plex:
            return true
        }
    }

    private static func mediaBrowserProgressSession(backend: MediaBrowserPlaybackProgressSession.Backend,
                                                    item: MediaItem,
                                                    context: MediaBrowserPlaybackContext,
                                                    mediaSourceId: String,
                                                    playSessionId: String,
                                                    playMethod: MediaBrowserPlayMethod) -> MediaBrowserPlaybackProgressSession? {
        guard let userID = context.session.userID else { return nil }
        return MediaBrowserPlaybackProgressSession(backend: backend,
                                                   server: context.session.baseURL,
                                                   token: context.session.token,
                                                   userID: userID,
                                                   identity: context.identity,
                                                   itemID: item.ratingKey,
                                                   mediaSourceID: mediaSourceId,
                                                   playSessionID: playSessionId,
                                                   playMethod: playMethod)
    }

    private static func adjustedResumeOffsetMs(_ offset: Int?, resumeRewindSeconds: Int) -> Int? {
        guard let offset, offset > 0, resumeRewindSeconds > 0 else { return offset }
        return max(0, offset - resumeRewindSeconds * 1000)
    }

    private static func copy(_ item: MediaItem, viewOffset: Int?) -> MediaItem {
        MediaItem(ratingKey: item.ratingKey, key: item.key, title: item.title, type: item.type,
                  duration: item.duration, viewOffset: viewOffset, viewCount: item.viewCount,
                  year: item.year, summary: item.summary, thumb: item.thumb, art: item.art, media: item.media,
                  librarySectionID: item.librarySectionID, librarySectionKey: item.librarySectionKey,
                  chapters: item.chapters, markers: item.markers, rating: item.rating,
                  contentRating: item.contentRating, tagline: item.tagline, genres: item.genres,
                  criticRating: item.criticRating, roles: item.roles, directors: item.directors,
                  studios: item.studios, logo: item.logo,
                  grandparentTitle: item.grandparentTitle, grandparentRatingKey: item.grandparentRatingKey,
                  grandparentThumb: item.grandparentThumb, parentTitle: item.parentTitle,
                  parentRatingKey: item.parentRatingKey, parentThumb: item.parentThumb,
                  parentIndex: item.parentIndex, index: item.index, originalTitle: item.originalTitle,
                  lastViewedAt: item.lastViewedAt, parentYear: item.parentYear,
                  ratingCount: item.ratingCount, composite: item.composite, leafCount: item.leafCount,
                  playlistType: item.playlistType,
                  primaryImageAspectRatio: item.primaryImageAspectRatio)
    }
}

struct DetailRemotePlaybackOpen {
    let playback: MediaBrowserRemotePlayback
    let playMethod: String
}

struct MediaBrowserPlaybackContext: Equatable, Sendable {
    let backend: MediaBackendKind
    let session: BackendSession
    let authRevision: Int
    let identity: ClientIdentity

    @MainActor
    func isCurrent(in appModel: AppModel) -> Bool {
        appModel.backendSession(for: backend.downloadBackendKind) == session
            && appModel.authSessionRevision(for: backend) == authRevision
            && appModel.identity == identity
    }
}

struct MediaBrowserRemotePlayback: Identifiable, Equatable {
    let id: UUID
    let context: MediaBrowserPlaybackContext
    let result: MediaBrowserPlaybackOpenResult
    /// Canonical `Media` index whose stream metadata backs the player's track pickers.
    let mediaIndex: Int

    init(id: UUID = UUID(),
         context: MediaBrowserPlaybackContext,
         result: MediaBrowserPlaybackOpenResult,
         mediaIndex: Int = 0) {
        precondition(context.backend != .plex, "Plex cannot produce MediaBrowser remote playback")
        self.id = id
        self.context = context
        self.result = result
        self.mediaIndex = mediaIndex
    }

    var backend: MediaBackendKind { context.backend }
    var url: URL { result.url }
    var headers: [String: String] { result.requiredHTTPHeaders }
    var playSessionId: String { result.playSessionId }
    var mediaSourceId: String { result.mediaSourceId }
    var sourceMetadata: MediaBrowserPlaybackSourceMetadata { result.sourceMetadata }
    var playMethod: MediaBrowserPlayMethod { result.playMethod }
    var usesServerEncoding: Bool { result.usesServerEncoding }
    var transcodeReasons: [String] { result.transcodeReasons }

    /// Jellyfin historically sends the idempotent active-encoding stop for every remote session;
    /// Emby must send it only for server-encoded streams. Preserve that backend contract exactly.
    var requiresActiveEncodingStop: Bool {
        backend == .jellyfin || usesServerEncoding
    }
}
