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

    static func openJellyfin(item: MediaItem,
                             appModel: AppModel,
                             maxVideoBitrateKbps: Int) async throws -> DetailRemotePlaybackOpen<JellyfinRemotePlayback> {
        let result = try await JellyfinBrowseService(appModel: appModel)
            .playbackOpen(item: item, maxVideoBitrateKbps: maxVideoBitrateKbps)
        return DetailRemotePlaybackOpen(
            playback: JellyfinRemotePlayback(url: result.url,
                                             headers: result.requiredHTTPHeaders,
                                             playSessionId: result.playSessionId,
                                             mediaSourceId: result.mediaSourceId,
                                             sourceMetadata: MediaBrowserPlaybackSourceMetadata(result.sourceMetadata),
                                             playMethod: MediaBrowserPlayMethod(result.playMethod)),
            playMethod: result.playMethod.rawValue)
    }

    static func openEmby(item: MediaItem,
                         appModel: AppModel,
                         maxVideoBitrateKbps: Int) async throws -> DetailRemotePlaybackOpen<EmbyRemotePlayback> {
        let result = try await EmbyBrowseService(appModel: appModel)
            .playbackOpen(item: item, maxVideoBitrateKbps: maxVideoBitrateKbps)
        return DetailRemotePlaybackOpen(
            playback: EmbyRemotePlayback(url: result.url,
                                         headers: result.requiredHTTPHeaders,
                                         playSessionId: result.playSessionId,
                                         mediaSourceId: result.mediaSourceId,
                                         sourceMetadata: MediaBrowserPlaybackSourceMetadata(result.sourceMetadata),
                                         playMethod: MediaBrowserPlayMethod(result.playMethod),
                                         usesServerEncoding: result.usesServerEncoding),
            playMethod: result.playMethod.rawValue)
    }

    static func jellyfinPlaybackController(remote: JellyfinRemotePlayback,
                                           item: MediaItem,
                                           appModel: AppModel,
                                           maxVideoBitrateKbps: Int,
                                           qualityDefaultsKey: String) -> PlaybackController {
        PlaybackController(remoteStreamURL: remote.url,
                           item: item,
                           identity: appModel.identity,
                           client: appModel.client,
                           remoteBackendLabel: "Jellyfin",
                           httpHeaders: remote.headers,
                           remotePlaySessionId: remote.playSessionId,
                           sourceMetadata: remote.sourceMetadata,
                           playMethod: remote.playMethod,
                           mediaBrowserProgressSession: mediaBrowserProgressSession(
                               backend: .jellyfin,
                               item: item,
                               appModel: appModel,
                               mediaSourceId: remote.mediaSourceId,
                               playSessionId: remote.playSessionId,
                               playMethod: remote.playMethod),
                           onStopRemoteSession: {
                               stopJellyfinActiveEncoding(appModel: appModel,
                                                          playSessionId: remote.playSessionId)
                           },
                           remoteStreamReopener: { request in
                               try await reopenJellyfinStream(item: item,
                                                             appModel: appModel,
                                                             request: request)
                           },
                           maxVideoBitrateKbps: maxVideoBitrateKbps,
                           qualityDefaultsKey: qualityDefaultsKey)
    }

    static func embyPlaybackController(remote: EmbyRemotePlayback,
                                       item: MediaItem,
                                       appModel: AppModel,
                                       maxVideoBitrateKbps: Int,
                                       qualityDefaultsKey: String) -> PlaybackController {
        PlaybackController(remoteStreamURL: remote.url,
                           item: item,
                           identity: appModel.identity,
                           client: appModel.client,
                           remoteBackendLabel: "Emby",
                           httpHeaders: remote.headers,
                           remotePlaySessionId: remote.playSessionId,
                           sourceMetadata: remote.sourceMetadata,
                           playMethod: remote.playMethod,
                           mediaBrowserProgressSession: mediaBrowserProgressSession(
                               backend: .emby,
                               item: item,
                               appModel: appModel,
                               mediaSourceId: remote.mediaSourceId,
                               playSessionId: remote.playSessionId,
                               playMethod: remote.playMethod),
                           onStopRemoteSession: {
                               stopEmbyActiveEncoding(appModel: appModel,
                                                      playSessionId: remote.playSessionId,
                                                      usesServerEncoding: remote.usesServerEncoding)
                           },
                           remoteStreamReopener: { request in
                               try await reopenEmbyStream(item: item,
                                                          appModel: appModel,
                                                          request: request)
                           },
                           maxVideoBitrateKbps: maxVideoBitrateKbps,
                           qualityDefaultsKey: qualityDefaultsKey)
    }

    private static func reopenJellyfinStream(item: MediaItem,
                                             appModel: AppModel,
                                             request: RemoteStreamReopenRequest) async throws -> RemoteStreamOpenResult {
        let result = try await JellyfinBrowseService(appModel: appModel)
            .playbackOpen(item: item,
                          maxVideoBitrateKbps: request.bitrateKbps,
                          resumeOffsetMs: request.offsetMs,
                          audioStreamIndex: request.audioStreamIndex,
                          subtitleStreamIndex: request.subtitleStreamIndex)
        return RemoteStreamOpenResult(
            url: result.url,
            headers: result.requiredHTTPHeaders,
            playSessionId: result.playSessionId,
            mediaSourceId: result.mediaSourceId,
            sourceMetadata: MediaBrowserPlaybackSourceMetadata(result.sourceMetadata),
            playMethod: MediaBrowserPlayMethod(result.playMethod),
            onStop: {
                stopJellyfinActiveEncoding(appModel: appModel,
                                           playSessionId: result.playSessionId)
            })
    }

    private static func reopenEmbyStream(item: MediaItem,
                                         appModel: AppModel,
                                         request: RemoteStreamReopenRequest) async throws -> RemoteStreamOpenResult {
        let result = try await EmbyBrowseService(appModel: appModel)
            .playbackOpen(item: item,
                          maxVideoBitrateKbps: request.bitrateKbps,
                          resumeOffsetMs: request.offsetMs,
                          audioStreamIndex: request.audioStreamIndex,
                          subtitleStreamIndex: request.subtitleStreamIndex)
        return RemoteStreamOpenResult(
            url: result.url,
            headers: result.requiredHTTPHeaders,
            playSessionId: result.playSessionId,
            mediaSourceId: result.mediaSourceId,
            sourceMetadata: MediaBrowserPlaybackSourceMetadata(result.sourceMetadata),
            playMethod: MediaBrowserPlayMethod(result.playMethod),
            onStop: {
                stopEmbyActiveEncoding(appModel: appModel,
                                       playSessionId: result.playSessionId,
                                       usesServerEncoding: result.usesServerEncoding)
            })
    }

    private static func stopJellyfinActiveEncoding(appModel: AppModel, playSessionId: String) {
        Task {
            await JellyfinBrowseService(appModel: appModel)
                .stopActiveEncoding(playSessionId: playSessionId)
        }
    }

    private static func stopEmbyActiveEncoding(appModel: AppModel,
                                               playSessionId: String,
                                               usesServerEncoding: Bool) {
        Task {
            if usesServerEncoding {
                await EmbyBrowseService(appModel: appModel)
                    .stopActiveEncoding(playSessionId: playSessionId)
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

struct DetailRemotePlaybackOpen<Playback> {
    let playback: Playback
    let playMethod: String
}

struct JellyfinRemotePlayback: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let headers: [String: String]
    let playSessionId: String
    let mediaSourceId: String
    let sourceMetadata: MediaBrowserPlaybackSourceMetadata
    let playMethod: MediaBrowserPlayMethod
}

struct EmbyRemotePlayback: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let headers: [String: String]
    let playSessionId: String
    let mediaSourceId: String
    let sourceMetadata: MediaBrowserPlaybackSourceMetadata
    let playMethod: MediaBrowserPlayMethod
    let usesServerEncoding: Bool
}
