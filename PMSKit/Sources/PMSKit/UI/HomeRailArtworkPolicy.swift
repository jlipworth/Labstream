import Foundation

/// Pure artwork-selection rules for Home rails.
///
/// Home is the one cross-content surface where an episode tile should read like TV
/// poster art when season/show context is available. Search and season-detail episode
/// lists still prefer 16:9 episode stills, so this stays as an explicit Home policy
/// rather than changing `MediaItem.thumb` globally.
public enum HomeRailArtworkPolicy {
    public enum Presentation: Sendable, Equatable {
        /// Poster-shaped artwork, rendered with the standard 2:3 rail card.
        case poster
        /// Episode-still/backdrop artwork, rendered as the existing 16:9 episode card.
        case landscape

        /// The selected artwork's width/height contract. Home uses this same value for its
        /// frame and backend request so a landscape Thumb can never be requested as a 2:3
        /// poster (the server may otherwise reshape the response before SwiftUI sees it).
        public var aspectRatio: Double {
            switch self {
            case .poster: MediaItem.defaultPosterAspect
            case .landscape: 16.0 / 9.0
            }
        }

        public func pixelHeight(forPixelWidth width: Int) -> Int {
            max(1, Int((Double(max(1, width)) / aspectRatio).rounded()))
        }
    }

    public struct Selection: Sendable, Equatable {
        public let path: String?
        public let presentation: Presentation

        public init(path: String?, presentation: Presentation) {
            self.path = path
            self.presentation = presentation
        }
    }

    /// Select the artwork path and shape for a Home rail item.
    ///
    /// Episodes prefer season-level artwork (`parentThumb`) before show/global art and
    /// only then fall back to episode still/backdrop imagery. Non-episode items keep the
    /// existing rail behavior and use their own `thumb` only.
    public static func selection(for item: MediaItem) -> Selection {
        guard item.kind == .episode else {
            return Selection(path: nonEmpty(item.thumb), presentation: .poster)
        }

        let seasonArtwork = classified(item.parentThumb, fallback: .poster)
        let showArtwork = classified(item.grandparentThumb, fallback: .poster)

        // MediaBrowser's ParentThumb is a landscape season thumbnail, despite the field's
        // historical use as "season artwork". Prefer an actual season/show Primary poster
        // before it so Home keeps portrait cards whenever the backend supplied one.
        if let seasonArtwork, seasonArtwork.presentation == .poster { return seasonArtwork }
        if let showArtwork, showArtwork.presentation == .poster { return showArtwork }

        // When no Primary exists, retain the available contextual image but honor its real
        // image type. A Thumb/Backdrop must flow through the 16:9 cell/request contract.
        if let seasonArtwork { return seasonArtwork }
        if let showArtwork { return showArtwork }
        if let episodeStill = classified(item.thumb, fallback: .landscape) { return episodeStill }
        return classified(item.art, fallback: .landscape)
            ?? Selection(path: nil, presentation: .landscape)
    }

    private static func classified(_ path: String?, fallback: Presentation) -> Selection? {
        guard let path = nonEmpty(path) else { return nil }
        let presentation: Presentation
        switch syntheticImageType(path) {
        case .primary:
            presentation = .poster
        case .thumb, .backdrop:
            presentation = .landscape
        case .logo, nil:
            // Plex paths do not encode an image type. Preserve the caller's established
            // semantic fallback for those paths rather than guessing from a URL shape.
            presentation = fallback
        }
        return Selection(path: path, presentation: presentation)
    }

    private static func syntheticImageType(_ path: String) -> MediaBrowserImageType? {
        guard let scheme = URL(string: path)?.scheme,
              scheme == JellyfinFlavor.syntheticScheme || scheme == EmbyFlavor.syntheticScheme else {
            return nil
        }
        return MediaBrowserSyntheticImageRef.parse(path, scheme: scheme)?.type
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
