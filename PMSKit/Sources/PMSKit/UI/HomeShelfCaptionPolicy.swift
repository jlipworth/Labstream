import Foundation

/// The context line under every card in one Home shelf (iPhone Duo design spec, Home and
/// "Color & type"). Siblings always show the same field, so one card never carries a year while
/// its neighbour does not, and unfinished items always read "23m left", never a bare length that
/// could be misread as the runtime.
public enum HomeShelfCaptionPolicy {
    public enum Kind: Equatable, Sendable {
        /// A resume shelf (any card has progress): every card shows the time left.
        case timeLeft
        /// Every card is an episode: "S1E3 · Title".
        case episode
        /// Every card has a year.
        case year
        /// No field every sibling shares: the title stands alone.
        case none
    }

    public static func kind(for items: [MediaItem]) -> Kind {
        guard !items.isEmpty else { return .none }
        if items.contains(where: { hasProgress($0) }) { return .timeLeft }
        if items.allSatisfy({ $0.kind == .episode }) { return .episode }
        if items.allSatisfy({ $0.year != nil }) { return .year }
        return .none
    }

    /// The caption for one card under the shelf's chosen kind; `nil` leaves the line empty
    /// (the cell still reserves it so rows stay aligned).
    public static func caption(for item: MediaItem, kind: Kind) -> String? {
        switch kind {
        case .timeLeft:
            guard let duration = item.duration, duration > 0 else { return nil }
            let offset = min(max(item.viewOffset ?? 0, 0), duration)
            return timeLeft(milliseconds: duration - offset)
        case .episode:
            let parts = [item.seasonEpisodeCode, item.title].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .year:
            return item.year.map(String.init)
        case .none:
            return nil
        }
    }

    /// "23m left", "1h 2m left", "1h left"; anything under a minute reads "1m left" so the
    /// caption stays two short words.
    public static func timeLeft(milliseconds: Int) -> String {
        let minutes = max(Int((Double(max(milliseconds, 0)) / 60_000).rounded()), 1)
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return "\(rest)m left" }
        if rest == 0 { return "\(hours)h left" }
        return "\(hours)h \(rest)m left"
    }

    private static func hasProgress(_ item: MediaItem) -> Bool {
        guard let offset = item.viewOffset, offset > 0,
              let duration = item.duration, duration > 0 else { return false }
        return offset < duration
    }
}
