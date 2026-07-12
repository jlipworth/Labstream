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
                             backend: MediaBackendKind,
                             appModel: AppModel,
                             resumeRewindSeconds: Int) async -> MediaItem {
        let fetched: MediaItem?
        switch backend {
        case .plex:
            fetched = nil
        case .jellyfin:
            fetched = try? await JellyfinBrowseService(appModel: appModel).metadata(itemId: ratingKey)
        case .emby:
            fetched = try? await EmbyBrowseService(appModel: appModel).metadata(itemId: ratingKey)
        }
        return itemWithResumeRewind(fetched ?? fallback, resumeRewindSeconds: resumeRewindSeconds)
    }

    enum OpenError: Error {
        case unsupportedBackend
    }

    static func open(item: MediaItem,
                     backend: MediaBackendKind,
                     appModel: AppModel,
                     maxVideoBitrateKbps: Int) async throws -> DetailRemotePlaybackOpen {
        let selection = MediaBrowserPlaybackPreferencePolicy.initialSelection(for: item)
        let result: MediaBrowserPlaybackOpenResult
        switch backend {
        case .jellyfin:
            result = try await JellyfinBrowseService(appModel: appModel)
                .playbackOpen(item: item,
                              maxVideoBitrateKbps: maxVideoBitrateKbps,
                              audioStreamIndex: selection.audioStreamIndex,
                              subtitleStreamIndex: selection.subtitleStreamIndex)
        case .emby:
            // The initial PlaybackInfo must carry explicit stream selection. Omitting the
            // subtitle sentinel lets Emby's server-side user profile burn in a default subtitle
            // while the app picker still shows Off.
            result = try await EmbyBrowseService(appModel: appModel)
                .playbackOpen(item: item,
                              maxVideoBitrateKbps: maxVideoBitrateKbps,
                              audioStreamIndex: selection.audioStreamIndex,
                              subtitleStreamIndex: selection.subtitleStreamIndex)
        case .plex:
            throw OpenError.unsupportedBackend
        }
        return DetailRemotePlaybackOpen(
            playback: MediaBrowserRemotePlayback(backend: backend, result: result),
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
        return PlaybackController(
            remoteStreamURL: remote.url,
            item: item,
            identity: appModel.identity,
            client: appModel.client,
            remoteBackendLabel: remote.backend.displayName,
            httpHeaders: remote.headers,
            remotePlaySessionId: remote.playSessionId,
            sourceMetadata: remote.sourceMetadata,
            playMethod: remote.playMethod,
            mediaBrowserProgressSession: mediaBrowserProgressSession(
                backend: progressBackend,
                item: item,
                appModel: appModel,
                mediaSourceId: remote.mediaSourceId,
                playSessionId: remote.playSessionId,
                playMethod: remote.playMethod),
            onStopRemoteSession: {
                stopActiveEncoding(remote: remote, appModel: appModel)
            },
            remoteStreamReopener: { request in
                try await reopenStream(backend: remote.backend,
                                       item: item,
                                       appModel: appModel,
                                       request: request)
            },
            initialAudioStreamIndex: MediaBrowserPlaybackPreferencePolicy
                .preferredAudioStreamIndex(for: item),
            initialSubtitleStreamIndex: MediaBrowserPlaybackPreferencePolicy
                .preferredSubtitleStreamIndex(for: item),
            maxVideoBitrateKbps: maxVideoBitrateKbps,
            qualityDefaultsKey: qualityDefaultsKey)
    }

    private static func reopenStream(backend: MediaBackendKind,
                                     item: MediaItem,
                                     appModel: AppModel,
                                     request: RemoteStreamReopenRequest) async throws -> RemoteStreamOpenResult {
        let result: MediaBrowserPlaybackOpenResult
        switch backend {
        case .jellyfin:
            result = try await JellyfinBrowseService(appModel: appModel)
                .playbackOpen(item: item,
                              maxVideoBitrateKbps: request.bitrateKbps,
                              resumeOffsetMs: request.offsetMs,
                              audioStreamIndex: request.audioStreamIndex,
                              subtitleStreamIndex: request.subtitleStreamIndex)
        case .emby:
            result = try await EmbyBrowseService(appModel: appModel)
                .playbackOpen(item: item,
                              maxVideoBitrateKbps: request.bitrateKbps,
                              resumeOffsetMs: request.offsetMs,
                              audioStreamIndex: request.audioStreamIndex,
                              subtitleStreamIndex: request.subtitleStreamIndex)
        case .plex:
            throw OpenError.unsupportedBackend
        }
        let reopened = MediaBrowserRemotePlayback(backend: backend, result: result)
        return RemoteStreamOpenResult(
            url: reopened.url,
            headers: reopened.headers,
            playSessionId: reopened.playSessionId,
            mediaSourceId: reopened.mediaSourceId,
            sourceMetadata: reopened.sourceMetadata,
            playMethod: reopened.playMethod,
            onStop: {
                stopActiveEncoding(remote: reopened, appModel: appModel)
            })
    }

    private static func stopActiveEncoding(remote: MediaBrowserRemotePlayback,
                                           appModel: AppModel) {
        guard remote.requiresActiveEncodingStop else { return }
        Task {
            switch remote.backend {
            case .jellyfin:
                await JellyfinBrowseService(appModel: appModel)
                    .stopActiveEncoding(playSessionId: remote.playSessionId)
            case .emby:
                await EmbyBrowseService(appModel: appModel)
                    .stopActiveEncoding(playSessionId: remote.playSessionId)
            case .plex:
                break
            }
        }
    }

    private static func mediaBrowserProgressSession(backend: MediaBrowserPlaybackProgressSession.Backend,
                                                    item: MediaItem,
                                                    appModel: AppModel,
                                                    mediaSourceId: String,
                                                    playSessionId: String,
                                                    playMethod: MediaBrowserPlayMethod) -> MediaBrowserPlaybackProgressSession? {
        let server: URL?
        let token: String?
        let userID: String?
        switch backend {
        case .jellyfin:
            server = appModel.jellyfinServerBaseURL
            token = appModel.jellyfinAccessToken
            userID = appModel.jellyfinUserID
        case .emby:
            server = appModel.embyServerBaseURL
            token = appModel.embyAccessToken
            userID = appModel.embyUserID
        }

        guard let server, let token, let userID else { return nil }
        return MediaBrowserPlaybackProgressSession(backend: backend,
                                                   server: server,
                                                   token: token,
                                                   userID: userID,
                                                   identity: appModel.identity,
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

struct MediaBrowserRemotePlayback: Identifiable, Equatable {
    let id: UUID
    let backend: MediaBackendKind
    let result: MediaBrowserPlaybackOpenResult

    init(id: UUID = UUID(), backend: MediaBackendKind, result: MediaBrowserPlaybackOpenResult) {
        precondition(backend != .plex, "Plex cannot produce MediaBrowser remote playback")
        self.id = id
        self.backend = backend
        self.result = result
    }

    var url: URL { result.url }
    var headers: [String: String] { result.requiredHTTPHeaders }
    var playSessionId: String { result.playSessionId }
    var mediaSourceId: String { result.mediaSourceId }
    var sourceMetadata: MediaBrowserPlaybackSourceMetadata { result.sourceMetadata }
    var playMethod: MediaBrowserPlayMethod { result.playMethod }
    var usesServerEncoding: Bool { result.usesServerEncoding }

    /// Jellyfin historically sends the idempotent active-encoding stop for every remote session;
    /// Emby must send it only for server-encoded streams. Preserve that backend contract exactly.
    var requiresActiveEncodingStop: Bool {
        backend == .jellyfin || usesServerEncoding
    }
}
