import Foundation

/// One entry of a library's A–Z jump rail: a display character, the count of items
/// under it, and the absolute item offset where that character's run begins (GH #96).
///
/// This is the canonical, backend-agnostic bucket type. Plex derives buckets from its
/// single `/firstCharacter` response; Jellyfin and Emby derive them from per-letter
/// count probes. Both feed the SAME offset math here (`buckets(from:total:)`) so the
/// rail jumps to the same place and renders identically across all three backends —
/// the offsets are no longer computed three different ways inline in the UI.
public struct AlphabetBucket: Sendable, Equatable {
    /// The character shown in the rail (e.g. "A", "#").
    public let display: String
    /// How many items fall under this character.
    public let count: Int
    /// Absolute index of the first item under this character, clamped into the
    /// `0..<total` range so it is always a valid scroll target.
    public let offset: Int

    public init(display: String, count: Int, offset: Int) {
        self.display = display
        self.count = count
        self.offset = offset
    }

    /// Build rail buckets from an ordered list of `(display, count)` pairs and the
    /// library's full item `total`. Computes running offsets, drops empty/blank
    /// characters, and clamps each offset to `0..<total` so a malformed count can
    /// never produce an out-of-range scroll target.
    ///
    /// Both the Plex single-call path and the Jellyfin/Emby probe path call this, so
    /// they produce identical `[AlphabetBucket]` for the same library.
    public static func buckets(from counts: [(display: String, count: Int)],
                               total: Int) -> [AlphabetBucket] {
        var runningOffset = 0
        var result: [AlphabetBucket] = []
        for entry in counts {
            let display = entry.display.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !display.isEmpty, entry.count > 0 else { continue }
            result.append(AlphabetBucket(display: display,
                                         count: entry.count,
                                         offset: min(runningOffset, max(total - 1, 0))))
            runningOffset += entry.count
        }
        return result
    }
}
