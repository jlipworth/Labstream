import Foundation
import PMSKit

/// One place that turns a `MediaItem` artwork path into an authenticated image request,
/// for every backend. The path is either a Plex image path (served through the
/// `/photo/:/transcode` resizer) or a `jellyfin://` / `emby://` synthetic ref minted by
/// `MediaBrowserBaseItemDto`. The ref's scheme is authoritative — search can surface
/// items from a backend that is not the active one — so each backend lane is tried by
/// scheme, then Plex as the default.
///
/// Both `PosterImage` (grid/detail art) and `MusicPlayerController` (system Now Playing
/// card) resolve artwork through here so there is a single, consistent construction.
@MainActor
enum MediaArtwork {
    /// Build an authenticated image request for `path`, sized to the given pixels.
    /// Returns nil when the path is empty/unresolvable or the matching backend lane is
    /// not configured.
    static func imageRequest(path: String?,
                             appModel: AppModel,
                             pixelWidth: Int,
                             pixelHeight: Int) -> URLRequest? {
        guard let path, !path.isEmpty else { return nil }

        if let base = appModel.embyServerBaseURL,
           let token = appModel.embyAccessToken,
           let userId = appModel.embyUserID,
           let req = (try? EmbyLibrary.posterRequest(syntheticRef: path,
                                                     server: base,
                                                     token: token,
                                                     identity: appModel.identity.emby,
                                                     userId: userId,
                                                     width: pixelWidth,
                                                     height: pixelHeight)) ?? nil {
            return req
        }

        if let base = appModel.jellyfinServerBaseURL,
           let token = appModel.jellyfinAccessToken,
           let req = (try? JellyfinLibrary.posterRequest(syntheticRef: path,
                                                         server: base,
                                                         token: token,
                                                         identity: appModel.identity.jellyfin,
                                                         width: pixelWidth,
                                                         height: pixelHeight)) ?? nil {
            return req
        }

        if let url = plexTranscodeURL(path: path, appModel: appModel,
                                      pixelWidth: pixelWidth, pixelHeight: pixelHeight) {
            return URLRequest(url: url)
        }
        return nil
    }

    /// Which backend an artwork `path` resolves against — used only for instrumentation
    /// labels, so it inspects the ref scheme without needing live credentials.
    static func backendLabel(for path: String?) -> String {
        if MediaBrowserSyntheticImageRef.parse(path, scheme: EmbyFlavor.syntheticScheme) != nil { return "Emby" }
        if MediaBrowserSyntheticImageRef.parse(path, scheme: JellyfinFlavor.syntheticScheme) != nil { return "Jellyfin" }
        return "Plex"
    }

    /// Plex `/photo/:/transcode` resizer URL (token in query — Plex images authenticate
    /// that way, unlike the header-authed MediaBrowser image endpoints).
    private static func plexTranscodeURL(path: String,
                                         appModel: AppModel,
                                         pixelWidth: Int,
                                         pixelHeight: Int) -> URL? {
        guard let base = appModel.serverBaseURL, let token = appModel.serverToken else { return nil }
        guard var comps = URLComponents(url: base.appendingPathComponent("/photo/:/transcode"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        PlexURLQueryEncoder.replaceQueryItems([
            .init(name: "url", value: path),
            .init(name: "width", value: String(pixelWidth)),
            .init(name: "height", value: String(pixelHeight)),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ], in: &comps)
        return comps.url
    }
}
