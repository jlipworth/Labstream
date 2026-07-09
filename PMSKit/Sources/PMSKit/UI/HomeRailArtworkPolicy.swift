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

        if let seasonArtwork = nonEmpty(item.parentThumb) {
            return Selection(path: seasonArtwork, presentation: .poster)
        }
        if let showArtwork = nonEmpty(item.grandparentThumb) {
            return Selection(path: showArtwork, presentation: .poster)
        }
        if let episodeStill = nonEmpty(item.thumb) {
            return Selection(path: episodeStill, presentation: .landscape)
        }
        return Selection(path: nonEmpty(item.art), presentation: .landscape)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
