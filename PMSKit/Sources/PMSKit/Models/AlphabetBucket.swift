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

    /// Build rail buckets directly from a fully-loaded, ordered display list (GH #108).
    ///
    /// For a COLLAPSING movie grid the displayed list is a stable, deduped, dense array
    /// (load-all + collapse), so the rail must index into THAT list — not the server's
    /// un-deduped offsets, which no longer line up after collapse (the F1 bug). Each bucket's
    /// `offset` is the index of the first list item whose first title character maps to that
    /// bucket, so `offset` is always a valid index into the displayed array and matches the
    /// grid's `.id(index)` scroll targets. `firstLetter` reduces each title to its rail token:
    /// A–Z (case-folded) for an alphabetic leading character, else "#".
    public static func buckets(fromTitles titles: [String]) -> [AlphabetBucket] {
        var firstIndexByToken: [String: Int] = [:]
        var countByToken: [String: Int] = [:]
        var tokenOrder: [String] = []
        for (index, title) in titles.enumerated() {
            let token = railToken(for: title)
            if firstIndexByToken[token] == nil {
                firstIndexByToken[token] = index
                tokenOrder.append(token)
            }
            countByToken[token, default: 0] += 1
        }
        // Present in the order the tokens first appear in the (already-sorted) list, so a
        // server sort that places "#"/digits before or after A–Z is honored as-is.
        return tokenOrder.map { token in
            AlphabetBucket(display: token,
                           count: countByToken[token] ?? 0,
                           offset: firstIndexByToken[token] ?? 0)
        }
    }

    /// The rail bucket token for a title: its uppercased first letter when alphabetic, else "#".
    ///
    /// Leading articles ("The"/"A"/"An") are stripped first so the token matches the server's
    /// sort-name ordering, which ignores those articles by default. Without this, a library
    /// sorted by sort name places "The Avengers" in the "A" run while the raw title tokenizes
    /// as "T", producing a stray, out-of-order "T" bucket at the front of the rail (GH #108).
    private static func railToken(for title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sortable = stripLeadingArticle(trimmed)
        guard let first = sortable.first else { return "#" }
        if first.isLetter { return String(first).uppercased() }
        return "#"
    }

    /// Drop a leading English article ("The "/"An "/"A ") to mirror the default
    /// Jellyfin/Emby/Plex sort-name collation. Longest article checked first so "An " isn't
    /// shadowed by "A ". Returns the original string when no article leads it.
    private static func stripLeadingArticle(_ title: String) -> String {
        let lowered = title.lowercased()
        for article in ["the ", "an ", "a "] where lowered.hasPrefix(article) {
            return String(title.dropFirst(article.count))
        }
        return title
    }
}
