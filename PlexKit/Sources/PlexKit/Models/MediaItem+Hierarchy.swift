import Foundation

// MARK: - TV hierarchy helpers + episode-leaf resolution
//
// A Plex `show` and `season` are *containers*: they carry NO `Media`/`Part`, so they
// cannot be transcoded or downloaded. Handing a `show`/`season` ratingKey to the
// transcode/optimize path makes PMS return HTTP 400. The only playable/downloadable
// LEAF is an `episode` (for TV) or a `movie`. These helpers classify an item and,
// given a container's children, resolve the correct leaf ratingKey to play/download.

extension MediaItem {
    /// Plex item types we care about for navigation/playback.
    public enum Kind: Sendable, Equatable {
        case movie
        case show
        case season
        case episode
        case artist
        case album
        case track
        case playlist
        case other(String)

        init(rawValue: String) {
            switch rawValue {
            case "movie": self = .movie
            case "show": self = .show
            case "season": self = .season
            case "episode": self = .episode
            case "artist": self = .artist
            case "album": self = .album
            case "track": self = .track
            case "playlist": self = .playlist
            default: self = .other(rawValue)
            }
        }
    }

    /// Strongly-typed item kind derived from the PMS `type` string.
    public var kind: Kind { Kind(rawValue: type) }

    /// True for music items (artist/album/track). Hidden from browse until a proper
    /// music experience exists (issue #15).
    public var isMusic: Bool {
        switch type { case "artist", "album", "track": return true; default: return false }
    }

    /// A LEAF is directly playable/downloadable: it owns (or can own) a `Media`/`Part`.
    /// Movies and episodes are leaves; shows and seasons are containers and must be
    /// drilled into before anything can be transcoded.
    public var isPlayableLeaf: Bool {
        switch kind {
        case .show, .season: return false
        // Music containers: an artist/album/playlist owns no Part; drill to tracks.
        case .artist, .album, .playlist: return false
        case .movie, .episode, .track: return true
        case .other: return true // be permissive for clip/etc; they carry Parts.
        }
    }

    /// True when this item is a container whose children must be loaded before playback
    /// (a show → seasons, a season → episodes).
    public var isContainer: Bool { kind == .show || kind == .season }

    /// True for music containers (an `artist` → albums, an `album` → tracks). Music
    /// navigation routes these to dedicated music views; `isContainer`'s routing in
    /// `DetailView` is video-only and stays untouched.
    public var isMusicContainer: Bool { type == "artist" || type == "album" }

    /// An episode-style label, Plex/Emby-style:
    /// `"{grandparentTitle} · S{parentIndex}E{index} · {title}"`, gracefully dropping any
    /// missing component (and falling back to just `title` when none are present).
    ///
    /// Examples:
    ///   - episode with full context → "Breaking Bad · S1E3 · …And the Bag's in the River"
    ///   - episode missing show name  → "S1E3 · …And the Bag's in the River"
    ///   - movie / bare item          → "Blade Runner"
    public var displaySubtitleLine: String {
        guard kind == .episode else { return title }
        var parts: [String] = []
        if let show = grandparentTitle, !show.isEmpty { parts.append(show) }
        if let code = seasonEpisodeCode { parts.append(code) }
        if !title.isEmpty { parts.append(title) }
        return parts.isEmpty ? title : parts.joined(separator: " · ")
    }

    /// "S{parentIndex}E{index}" when both numbers are present, else just whichever is
    /// known, else `nil`.
    public var seasonEpisodeCode: String? {
        switch (parentIndex, index) {
        case let (s?, e?): return "S\(s)E\(e)"
        case let (s?, nil): return "S\(s)"
        case let (nil, e?): return "E\(e)"
        case (nil, nil): return nil
        }
    }
}

/// Resolves the correct LEAF `MediaItem` (the one with a `Media`/`Part`) to play or
/// download, given an item and — for containers — a way to fetch its children.
///
/// This is the regression guard for the HTTP 400 bug: the resolver NEVER returns a
/// `show` or `season` as the playback/download target. It walks show → first season →
/// first episode (or season → first episode) using the supplied children loader.
public enum EpisodeResolver {
    /// Resolution failures, surfaced so the UI can show a sensible message instead of
    /// silently handing PMS a bad ratingKey.
    public enum ResolveError: Error, Sendable, Equatable {
        /// A container (show/season) had no episodes to resolve to.
        case noEpisodes
        /// The resolved candidate was still a container (should never happen; guards the
        /// invariant that we never play/download a show/season).
        case notALeaf
    }

    /// Synchronously resolve a leaf when one is already in hand: a movie/episode resolves
    /// to itself; a container returns `nil` (the caller must fetch children and use
    /// ``resolveLeaf(from:loadChildren:)``).
    public static func leafIfAvailable(_ item: MediaItem) -> MediaItem? {
        item.isPlayableLeaf ? item : nil
    }

    /// Resolve the leaf episode to play/download for `item`.
    ///
    /// - For a `movie`/`episode`: returns the item itself.
    /// - For a `season`: loads its children (episodes) and returns the first episode.
    /// - For a `show`: loads its children (seasons), then the first season's children
    ///   (episodes), and returns the first episode.
    ///
    /// `loadChildren` is an async closure mapping a container ratingKey → its child
    /// `MediaItem`s (typically `/library/metadata/{ratingKey}/children`). Injecting it
    /// keeps this resolver pure and unit-testable with no network.
    public static func resolveLeaf(
        from item: MediaItem,
        loadChildren: (String) async throws -> [MediaItem]
    ) async throws -> MediaItem {
        // Already a leaf → done. This is the movie / direct-episode fast path and the
        // guarantee that a leaf is never re-walked.
        if item.isPlayableLeaf { return item }

        switch item.kind {
        case .season:
            let episodes = try await loadChildren(item.ratingKey)
            guard let first = firstLeaf(in: episodes) else { throw ResolveError.noEpisodes }
            return first

        case .show:
            let seasons = try await loadChildren(item.ratingKey)
            for season in seasons {
                // A season's children are its episodes; return the first leaf found.
                let episodes = try await loadChildren(season.ratingKey)
                if let first = firstLeaf(in: episodes) { return first }
            }
            throw ResolveError.noEpisodes

        default:
            // Unreachable: non-leaf, non-container types fall here. Treat defensively.
            throw ResolveError.notALeaf
        }
    }

    /// First playable leaf in a children list, preferring the lowest episode `index`
    /// when present so "play the show" starts at the earliest episode rather than
    /// whatever order PMS happened to return.
    private static func firstLeaf(in items: [MediaItem]) -> MediaItem? {
        let leaves = items.filter { $0.isPlayableLeaf }
        guard !leaves.isEmpty else { return nil }
        // Stable sort by (parentIndex, index) when known; items without indices keep
        // their server order at the end.
        return leaves.sorted { lhs, rhs in
            let l = (lhs.parentIndex ?? Int.max, lhs.index ?? Int.max)
            let r = (rhs.parentIndex ?? Int.max, rhs.index ?? Int.max)
            return l < r
        }.first
    }
}
