import CryptoKit
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
    /// Resolve point-space presentation into the exact server/decode pixel contract. Ordinary
    /// posters follow the real screen scale (including 3x phones); explicitly inexpensive
    /// decorative art may retain its existing 1x override.
    static func pixelDimensions(width: CGFloat,
                                height: CGFloat,
                                displayScale: CGFloat,
                                requestScale: CGFloat?) -> (width: Int, height: Int) {
        let candidate = requestScale ?? displayScale
        let scale = candidate.isFinite && candidate > 0 ? candidate : 1
        func pixels(_ points: CGFloat) -> Int {
            let value = points * scale
            guard value.isFinite, value > 0, value <= CGFloat(Int.max) else { return 1 }
            return max(1, Int(ceil(value)))
        }
        return (pixels(width), pixels(height))
    }

    /// Resolve one ordinary UI artwork source against the backend lane that owns it.
    ///
    /// Synthetic Jellyfin/Emby refs deliberately ignore `activeBackend`: search and other
    /// cross-backend surfaces may keep an item from an inactive, still-authenticated lane. The
    /// exact opaque browse authority is captured in the task identity so same-path re-auth or
    /// server changes restart the SwiftUI task without exposing credentials.
    static func descriptor(path: String?,
                           appModel: AppModel,
                           purpose: ArtworkPurpose = .poster,
                           pixelWidth: Int,
                           pixelHeight: Int) -> ArtworkRequestDescriptor? {
        guard let path, !path.isEmpty,
              pixelWidth > 0, pixelHeight > 0 else { return nil }
        let backend = owningBackend(for: path)
        guard let context = appModel.authenticatedBrowseSession(for: backend),
              let request = request(path: path,
                                    context: context,
                                    pixelWidth: pixelWidth,
                                    pixelHeight: pixelHeight) else { return nil }
        let digest = Data(SHA256.hash(data: Data(path.utf8)))
        let identity = ArtworkTaskIdentity(backend: backend,
                                           authority: .authenticated(context.authority),
                                           purpose: purpose,
                                           sourceDigest: digest,
                                           pixelWidth: pixelWidth,
                                           pixelHeight: pixelHeight)
        return ArtworkRequestDescriptor(taskIdentity: identity, request: request)
    }

    /// Which backend an artwork `path` resolves against — used only for instrumentation
    /// labels, so it inspects the ref scheme without needing live credentials.
    static func backendLabel(for path: String?) -> String {
        owningBackend(for: path ?? "").displayName
    }

    private static func owningBackend(for path: String) -> MediaBackendKind {
        switch URL(string: path)?.scheme {
        case EmbyFlavor.syntheticScheme: .emby
        case JellyfinFlavor.syntheticScheme: .jellyfin
        default: .plex
        }
    }

    private static func request(path: String,
                                context: AuthenticatedBrowseSessionContext,
                                pixelWidth: Int,
                                pixelHeight: Int) -> URLRequest? {
        switch context.backend {
        case .emby:
            guard let userID = context.session.userID else { return nil }
            return (try? EmbyLibrary.posterRequest(syntheticRef: path,
                                                   server: context.session.baseURL,
                                                   token: context.session.token,
                                                   identity: context.clientIdentity.emby,
                                                   userId: userID,
                                                   width: pixelWidth,
                                                   height: pixelHeight)) ?? nil
        case .jellyfin:
            return (try? JellyfinLibrary.posterRequest(syntheticRef: path,
                                                       server: context.session.baseURL,
                                                       token: context.session.token,
                                                       identity: context.clientIdentity.jellyfin,
                                                       width: pixelWidth,
                                                       height: pixelHeight)) ?? nil
        case .plex:
            guard let url = PlexPhotoTranscode.url(server: context.session.baseURL,
                                                   token: context.session.token,
                                                   imagePath: path,
                                                   width: pixelWidth,
                                                   height: pixelHeight) else { return nil }
            return URLRequest(url: url)
        }
    }
}
