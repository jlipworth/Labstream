import Foundation

/// Bounded re-ranking, not retrieval: every server hit survives and no extra requests
/// are issued. Scores only affect order inside an existing library/type section.
public enum SearchTitleRanking {
    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    public static func ranked(_ items: [MediaItem], query: String) -> [MediaItem] {
        let query = normalized(query)
        guard !query.isEmpty else { return items }
        let tokens = query.split(separator: " ").map(String.init)
        return items.enumerated().map { index, item in
            let title = normalized(item.title)
            return (item: item, title: title, score: score(title, query: query, tokens: tokens), index: index)
        }.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            // Keep server relevance for non-title hits, e.g. actor/description matches.
            if $0.score == 5 { return $0.index < $1.index }
            if $0.title != $1.title { return $0.title < $1.title }
            if $0.item.ratingKey != $1.item.ratingKey { return $0.item.ratingKey < $1.item.ratingKey }
            return $0.index < $1.index
        }.map(\.item)
    }

    private static func score(_ title: String, query: String, tokens: [String]) -> Int {
        if title == query { return 0 }
        if title.hasPrefix(query) { return 1 }
        let words = title.split(separator: " ").map(String.init)
        if matches(tokens, words: words, fuzzy: false) { return 2 }
        if title.contains(query) { return 3 }
        // Typo work is capped, and short words never receive fuzzy matches.
        if tokens.count <= 16, words.count <= 64,
           matches(tokens, words: words, fuzzy: true) { return 4 }
        return 5
    }

    private static func matches(_ tokens: [String], words: [String], fuzzy: Bool) -> Bool {
        guard tokens.count <= words.count else { return false }
        // A word can satisfy only one query token. Use a small augmenting-path
        // match so an early fuzzy candidate cannot steal a later token's only word.
        let candidates = tokens.map { token in
            words.indices.filter {
                words[$0].hasPrefix(token) || (fuzzy && token.count >= 4 && token.count <= 64
                    && words[$0].count <= 64 && oneEditApart(token, words[$0]))
            }
        }
        guard candidates.allSatisfy({ !$0.isEmpty }) else { return false }
        var owners = [Int?](repeating: nil, count: words.count)
        func assign(_ token: Int, visited: inout Set<Int>) -> Bool {
            for word in candidates[token] where visited.insert(word).inserted {
                if let owner = owners[word], !assign(owner, visited: &visited) { continue }
                owners[word] = token
                return true
            }
            return false
        }
        for token in tokens.indices {
            var visited = Set<Int>()
            guard assign(token, visited: &visited) else { return false }
        }
        return true
    }

    /// One insertion, deletion, substitution, or adjacent transposition (Damerau).
    private static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count == b.count {
                if i + 1 < a.count, a[i] == b[j + 1], a[i + 1] == b[j] {
                    i += 2; j += 2
                } else { i += 1; j += 1 }
            } else if a.count > b.count { i += 1 }
            else { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}
