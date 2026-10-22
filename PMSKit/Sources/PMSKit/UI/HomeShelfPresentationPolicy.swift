import Foundation

/// Home chooses geometry once per shelf, independently of each source image's shape.
/// Other surfaces continue to use their own artwork policies.
public enum HomeShelfPresentationPolicy {
    public static func presentation(for hub: Hub) -> HomeRailArtworkPolicy.Presentation? {
        switch hub.type {
        case "episode": return .landscape
        case "movie", "show", "season": return .poster
        default:
            // MediaBrowser shelves have no declared hub type. Use content semantics,
            // never PrimaryImageAspectRatio or whichever image finishes loading first.
            for item in hub.metadata {
                switch item.kind {
                case .episode: return .landscape
                case .movie, .show, .season: return .poster
                default: continue
                }
            }
            return nil // Music/photo shelves retain their existing presentation.
        }
    }

    public static func artwork(for item: MediaItem,
                               presentation: HomeRailArtworkPolicy.Presentation)
        -> HomeRailArtworkPolicy.Selection {
        if presentation == .landscape, item.kind == .episode {
            // Episode shelves prefer a still, but crop a contextual poster if that is
            // all the backend supplied. Empty paths must not suppress the fallback.
            let path = [item.thumb, item.art, item.parentThumb, item.grandparentThumb]
                .compactMap { $0 }.first { !$0.isEmpty }
            return .init(path: path, presentation: .landscape)
        }
        return HomeRailArtworkPolicy.selection(for: item)
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
