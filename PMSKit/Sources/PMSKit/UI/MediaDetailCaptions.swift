import Foundation

/// Context lines for the iPhone/iPad detail pages (iPhone Duo design spec, Movie detail, Show
/// detail and "Color & type").
///
/// Every line is a Caption: short fields joined by " · ", never wrapping. Unfinished items read
/// "23m left" (never a bare length that could be misread as the runtime), and an episode row
/// names only its episode number because the season is the screen title.
public enum MediaDetailCaptions {
    /// "1h 59m", "45m", "2h"; `nil` for a missing or non-positive duration.
    public static func runtime(milliseconds: Int?) -> String? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        let minutes = max(Int((Double(milliseconds) / 60_000).rounded()), 1)
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m" }
        if rest == 0 { return "\(hours)h" }
        return "\(hours)h \(rest)m"
    }

    /// "23m left" while the item is started but unfinished; otherwise `nil`.
    public static func timeLeft(for item: MediaItem) -> String? {
        guard let duration = item.duration, duration > 0,
              let offset = item.viewOffset, offset > 0, offset < duration else { return nil }
        return HomeShelfCaptionPolicy.timeLeft(milliseconds: duration - offset)
    }

    /// Movie or episode detail: year · runtime · content rating, in that order, skipping what is
    /// missing. Callers drop trailing fields when the line would not fit on one line.
    public static func movieContext(_ item: MediaItem) -> [String] {
        var parts: [String] = []
        if let year = item.year { parts.append(String(year)) }
        if let runtime = runtime(milliseconds: item.duration) { parts.append(runtime) }
        if let rating = trimmed(item.contentRating) { parts.append(rating) }
        return parts
    }

    /// Show header: "3 seasons · TV-14" (falls back to the year when the season count is unknown).
    public static func showContext(seasonCount: Int?, contentRating: String?, year: Int?) -> [String] {
        var parts: [String] = []
        if let seasonCount, seasonCount > 0 {
            parts.append(seasonCount == 1 ? "1 season" : "\(seasonCount) seasons")
        } else if let year {
            parts.append(String(year))
        }
        if let rating = trimmed(contentRating) { parts.append(rating) }
        return parts
    }

    /// Season header and season poster caption: "8 episodes" / "1 episode".
    public static func episodeCount(_ count: Int?) -> String? {
        guard let count, count > 0 else { return nil }
        return count == 1 ? "1 episode" : "\(count) episodes"
    }

    /// Episode row context line: "E1 · 38m", or "E3 · 23m left" while unfinished. The season
    /// is the screen title, so only the episode number is shown.
    public static func episodeRow(_ episode: MediaItem) -> String {
        var parts: [String] = []
        if let index = episode.index { parts.append("E\(index)") }
        if let left = timeLeft(for: episode) {
            parts.append(left)
        } else if let runtime = runtime(milliseconds: episode.duration) {
            parts.append(runtime)
        }
        return parts.joined(separator: " · ")
    }

    /// "S1, E3", the episode reference used by the show's resume action; `nil` without indices.
    public static func episodeReference(_ episode: MediaItem) -> String? {
        switch (episode.parentIndex, episode.index) {
        case let (season?, number?): return "S\(season), E\(number)"
        case let (nil, number?): return "E\(number)"
        default: return nil
        }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// The show page's one prominent action (Resolved decision 8): "Resume S1, E3" with "23m left"
/// for a started episode, otherwise "Play" for the next episode to watch.
public struct ShowResumePlan: Equatable, Sendable {
    public enum Action: Hashable, Sendable {
        case resume
        case play
    }

    public let episode: MediaItem
    public let action: Action

    public init(episode: MediaItem, action: Action) {
        self.episode = episode
        self.action = action
    }

    /// Plans are equal when they act on the same episode the same way.
    public static func == (lhs: ShowResumePlan, rhs: ShowResumePlan) -> Bool {
        lhs.episode.ratingKey == rhs.episode.ratingKey && lhs.action == rhs.action
    }

    /// "Resume S1, E3" / "Play S1, E4"; bare "Resume"/"Play" without episode numbers.
    public var label: String {
        let verb = action == .resume ? "Resume" : "Play"
        guard let reference = MediaDetailCaptions.episodeReference(episode) else { return verb }
        return "\(verb) \(reference)"
    }

    /// "23m left" for a resume, `nil` for a fresh play.
    public var timeLeft: String? {
        action == .resume ? MediaDetailCaptions.timeLeft(for: episode) : nil
    }

    /// Picks the episode from every episode of the show (any order):
    ///
    /// 1. A started, unwatched episode: the most recently viewed one (`lastViewedAt`), else the
    ///    latest in season/episode order.
    /// 2. Otherwise the first unwatched regular episode after the last watched one.
    /// 3. Otherwise (nothing watched, or everything after it watched) the first regular episode.
    ///
    /// Specials (season 0) are only chosen when they are in progress or are all there is.
    public static func plan(episodes: [MediaItem]) -> ShowResumePlan? {
        let ordered = episodes.filter { $0.kind == .episode }.sortedByEpisodeOrder()
        guard !ordered.isEmpty else { return nil }

        let started = ordered.enumerated().filter { _, episode in
            !isWatched(episode) && MediaDetailCaptions.timeLeft(for: episode) != nil
        }
        if !started.isEmpty {
            let chosen = started.max { lhs, rhs in
                let l = (lhs.element.lastViewedAt ?? Int.min, lhs.offset)
                let r = (rhs.element.lastViewedAt ?? Int.min, rhs.offset)
                return l < r
            }
            if let chosen { return ShowResumePlan(episode: chosen.element, action: .resume) }
        }

        let regular = ordered.filter { ($0.parentIndex ?? 1) != 0 }
        let pool = regular.isEmpty ? ordered : regular
        if let lastWatched = pool.lastIndex(where: isWatched) {
            if let next = pool[(lastWatched + 1)...].first(where: { !isWatched($0) }) {
                return ShowResumePlan(episode: next, action: .play)
            }
        }
        return ShowResumePlan(episode: pool[0], action: .play)
    }

    private static func isWatched(_ episode: MediaItem) -> Bool {
        (episode.viewCount ?? 0) > 0
    }
}
