import Foundation
import PMSKit

/// One place that turns a `MediaItem` artwork path into an authenticated image request,
/// for every backend. The path is either a Plex image path (served through the
/// `/photo/:/transcode` resizer) or a `jellyfin://` / `emby://` synthetic ref minted by
/// `MediaBrowserBaseItemDto`. The ref's scheme is authoritative — search can surface
/// items from a backend that is not the active one — so a synthetic scheme resolves only
/// through its owning backend, and Plex is used only for ordinary unschemed image paths.
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

        let scheme = URL(string: path)?.scheme

        if scheme == EmbyFlavor.syntheticScheme {
            guard let base = appModel.embyServerBaseURL,
                  let token = appModel.embyAccessToken,
                  let userId = appModel.embyUserID else { return nil }
            return (try? EmbyLibrary.posterRequest(syntheticRef: path,
                                                   server: base,
                                                   token: token,
                                                   identity: appModel.identity.emby,
                                                   userId: userId,
                                                   width: pixelWidth,
                                                   height: pixelHeight)) ?? nil
        }

        if scheme == JellyfinFlavor.syntheticScheme {
            guard let base = appModel.jellyfinServerBaseURL,
                  let token = appModel.jellyfinAccessToken else { return nil }
            return (try? JellyfinLibrary.posterRequest(syntheticRef: path,
                                                       server: base,
                                                       token: token,
                                                       identity: appModel.identity.jellyfin,
                                                       width: pixelWidth,
                                                       height: pixelHeight)) ?? nil
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
        if URL(string: path ?? "")?.scheme == EmbyFlavor.syntheticScheme { return "Emby" }
        if URL(string: path ?? "")?.scheme == JellyfinFlavor.syntheticScheme { return "Jellyfin" }
        return "Plex"
    }

    /// Plex `/photo/:/transcode` resizer URL via the shared `PlexPhotoTranscode` builder.
    private static func plexTranscodeURL(path: String,
                                         appModel: AppModel,
                                         pixelWidth: Int,
                                         pixelHeight: Int) -> URL? {
        guard let base = appModel.serverBaseURL, let token = appModel.serverToken else { return nil }
        return PlexPhotoTranscode.url(server: base, token: token, imagePath: path,
                                      width: pixelWidth, height: pixelHeight)
    }
}
