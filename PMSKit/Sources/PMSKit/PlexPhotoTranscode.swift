import Foundation

/// Single home for the Plex `/photo/:/transcode` image-resize URL.
///
/// The token rides in the query string — Plex images authenticate that way, unlike the
/// header-authed MediaBrowser image endpoints. The width/height are caller-specific
/// (grid/detail pixels, player chrome art, cached download posters), so they are parameters;
/// the URL/minSize/upscale/token assembly is shared so a change to how Plex artwork is
/// requested lands in exactly one place. Used by `MediaArtwork`, `PlaybackController`
/// (chrome art), and `DownloadManager` (cached posters).
public enum PlexPhotoTranscode {
    public static func url(server: URL,
                           token: String,
                           imagePath: String,
                           width: Int,
                           height: Int) -> URL? {
        guard let scheme = server.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = server.host, !host.isEmpty,
              !imagePath.isEmpty,
              width > 0, height > 0 else { return nil }
        guard var comps = URLComponents(url: server.appendingPathComponent("/photo/:/transcode"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        PlexURLQueryEncoder.replaceQueryItems([
            .init(name: "url", value: imagePath),
            .init(name: "width", value: String(width)),
            .init(name: "height", value: String(height)),
            .init(name: "minSize", value: "1"),
            .init(name: "upscale", value: "1"),
            .init(name: "X-Plex-Token", value: token),
        ], in: &comps)
        return comps.url
    }
}
