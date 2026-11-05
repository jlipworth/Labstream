import Foundation

/// Home chooses geometry once per shelf, independently of each source image's shape.
/// Every video shelf — including mixed Continue Watching and episode-only On Deck — uses
/// poster cards, so a shelf's shape never depends on which item happens to sort first.
/// Episodes show season/show posters here; stills stay on episode-centric surfaces
/// (season detail, search). Other surfaces continue to use their own artwork policies.
public enum HomeShelfPresentationPolicy {
    public static func presentation(for hub: Hub) -> HomeRailArtworkPolicy.Presentation? {
        switch hub.type {
        case "movie", "show", "season", "episode": return .poster
        default:
            // MediaBrowser and Plex "mixed" shelves: any video content makes it a poster
            // shelf. Never use PrimaryImageAspectRatio or image load order.
            let isVideoShelf = hub.metadata.contains { item in
                switch item.kind {
                case .movie, .show, .season, .episode: true
                default: false
                }
            }
            return isVideoShelf ? .poster : nil // Music/photo shelves retain their presentation.
        }
    }

    /// Contextual artwork for a Home card. Episodes prefer season, then show Primary
    /// posters; a landscape still/thumb is only the fallback and is cropped into the frame.
    public static func artwork(for item: MediaItem,
                               presentation: HomeRailArtworkPolicy.Presentation)
        -> HomeRailArtworkPolicy.Selection {
        HomeRailArtworkPolicy.selection(for: item)
    }

    /// Request the source in its own aspect before the view crops it into the shelf frame.
    /// In particular, do not ask a backend to reshape a landscape movie into a poster.
    public static func sourceAspect(for item: MediaItem,
                                    artwork: HomeRailArtworkPolicy.Selection) -> Double {
        if let path = artwork.path,
           let scheme = URL(string: path)?.scheme,
           scheme == "jellyfin" || scheme == "emby",
           let image = MediaBrowserSyntheticImageRef.parse(path, scheme: scheme),
           image.type == .thumb || image.type == .backdrop {
            return HomeRailArtworkPolicy.Presentation.landscape.aspectRatio
        }
        if artwork.path == item.thumb {
            return item.resolvedPosterAspect(fallback: artwork.presentation.aspectRatio)
        }
        let contextual = HomeRailArtworkPolicy.selection(for: item)
        if contextual.path == artwork.path {
            return contextual.presentation.aspectRatio
        }
        return artwork.presentation.aspectRatio
    }
}
