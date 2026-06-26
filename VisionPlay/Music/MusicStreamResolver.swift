import Foundation
import PMSKit

/// Resolves a track `MediaItem` to a playable audio stream for the active backend (#111).
/// This is the one place the music player asks "how do I stream this track", so the
/// player itself carries no backend knowledge.
///
/// Auth model mirrors the proven video path:
///   • Plex bakes `X-Plex-Token` into the stream URL (AVPlayer's loader can't carry our
///     API headers, and Plex authenticates images/streams that way).
///   • Jellyfin/Emby keep the token OUT of the URL and pass the MediaBrowser
///     `Authorization` header through `AVURLAssetHTTPHeaderFieldsKey` instead — exactly
///     how `PlaybackController.loadRemoteStream` authenticates video.
@MainActor
enum MusicStreamResolver {

    struct Stream {
        let url: URL
        /// Headers to attach to the `AVURLAsset` (empty for Plex).
        let headers: [String: String]
    }

    enum ResolveError: LocalizedError {
        case notConnected
        case noPlayableFile

        var errorDescription: String? {
            switch self {
            case .notConnected:   return "Not connected to a server."
            case .noPlayableFile: return "This track has no playable file."
            }
        }
    }

    static func stream(for track: MediaItem, appModel: AppModel) throws -> Stream {
        switch appModel.activeBackend {
        case .plex:
            guard let server = appModel.serverBaseURL, let token = appModel.serverToken else {
                throw ResolveError.notConnected
            }
            guard let partKey = track.media?.first?.part.first?.key else {
                throw ResolveError.noPlayableFile
            }
            return Stream(url: MusicRequest.trackStreamURL(server: server, token: token, partKey: partKey),
                          headers: [:])

        case .jellyfin:
            guard let server = appModel.jellyfinServerBaseURL,
                  let token = appModel.jellyfinAccessToken,
                  let userID = appModel.jellyfinUserID else {
                throw ResolveError.notConnected
            }
            let identity = appModel.identity.jellyfin
            let url = try JellyfinLibrary.audioStreamURL(server: server,
                                                         identity: identity,
                                                         userId: userID,
                                                         itemId: track.ratingKey,
                                                         maxStreamingBitrate: musicBitrate(appModel))
            let req = JellyfinLibrary.authenticatedRequest(url: url, token: token, identity: identity)
            return Stream(url: url, headers: req.allHTTPHeaderFields ?? [:])

        case .emby:
            guard let server = appModel.embyServerBaseURL,
                  let token = appModel.embyAccessToken,
                  let userID = appModel.embyUserID else {
                throw ResolveError.notConnected
            }
            let identity = appModel.identity.emby
            let url = try EmbyLibrary.audioStreamURL(server: server,
                                                     identity: identity,
                                                     userId: userID,
                                                     itemId: track.ratingKey,
                                                     maxStreamingBitrate: musicBitrate(appModel))
            let req = EmbyLibrary.authenticatedRequest(url: url, token: token,
                                                       identity: identity, userId: userID)
            return Stream(url: url, headers: req.allHTTPHeaderFields ?? [:])
        }
    }

    /// MediaBrowser `MaxStreamingBitrate` (bps). Honors the user's streaming-quality cap
    /// when one is set, otherwise keeps the generous direct-play default so lossless
    /// sources stream as-is. A cap below CD quality still transcodes via the universal
    /// endpoint's HLS fallback.
    private static func musicBitrate(_ appModel: AppModel) -> Int {
        let kbps = appModel.activeStreamingQualityKbps
        return kbps > 0 ? kbps * 1_000 : 140_000_000
    }
}
