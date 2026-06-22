import Testing
import Foundation
@testable import PMSKit

// MARK: - Backend-agnostic episode ordering (GH #106)
//
// Emby/Jellyfin fetch season children with `SortBy=SortName` (alphabetical by title),
// scrambling episodes into arbitrary order (e.g. S4E4, E1, E2, E10). `sortedByEpisodeOrder()`
// is the client-side numeric sort applied at the render seam so every backend shows
// episodes in broadcast order. These tests pin its behavior headlessly.

private func episode(_ rk: String, parentIndex: Int? = 1, index: Int?, title: String = "Ep") -> MediaItem {
    MediaItem(ratingKey: rk, title: title, type: "episode", parentIndex: parentIndex, index: index)
}

@Test func sortsAscendingEpisodesWithMultiDigitNotLexicographic() {
    // Shuffle E1..E11; the bug surfaces if E10/E11 sort before E2 (string order).
    let input = [
        episode("e3", index: 3), episode("e11", index: 11), episode("e1", index: 1),
        episode("e10", index: 10), episode("e2", index: 2), episode("e9", index: 9),
    ]
    let order = input.sortedByEpisodeOrder().map(\.index)
    #expect(order == [1, 2, 3, 9, 10, 11])
}

@Test func sortsReportedScrambledOrder() {
    // The exact shape from the issue: a single season rendered as S4E4, E1, E2, E10.
    let input = [
        episode("a", parentIndex: 4, index: 4),
        episode("b", parentIndex: 4, index: 1),
        episode("c", parentIndex: 4, index: 2),
        episode("d", parentIndex: 4, index: 10),
    ]
    let order = input.sortedByEpisodeOrder().map(\.index)
    #expect(order == [1, 2, 4, 10])
}

@Test func sortsSpecialsAndSeasonZeroFirst() {
    // Specials (season 0) sort before season 1; episode 0 before episode 1 within a season.
    let input = [
        episode("s1e2", parentIndex: 1, index: 2),
        episode("s0e1", parentIndex: 0, index: 1),
        episode("s1e1", parentIndex: 1, index: 1),
        episode("s1e0", parentIndex: 1, index: 0),
        episode("s0e0", parentIndex: 0, index: 0),
    ]
    let order = input.sortedByEpisodeOrder().map(\.ratingKey)
    #expect(order == ["s0e0", "s0e1", "s1e0", "s1e1", "s1e2"])
}

@Test func placesMissingIndexFirstButStably() {
    // A nil index defaults to 0, so unnumbered items sort to the front; among themselves
    // (and ties) they keep their original relative order (stable).
    let input = [
        episode("e2", index: 2),
        episode("nilA", index: nil, title: "Alpha"),
        episode("e1", index: 1),
        episode("nilB", index: nil, title: "Bravo"),
    ]
    let order = input.sortedByEpisodeOrder().map(\.ratingKey)
    #expect(order == ["nilA", "nilB", "e1", "e2"])
}

@Test func missingParentIndexDefaultsToSeasonZero() {
    // parentIndex nil -> 0, so it groups with specials ahead of numbered seasons.
    let input = [
        episode("s1e1", parentIndex: 1, index: 1),
        episode("noSeason", parentIndex: nil, index: 5),
    ]
    let order = input.sortedByEpisodeOrder().map(\.ratingKey)
    #expect(order == ["noSeason", "s1e1"])
}

@Test func alreadySortedInputIsUnchanged() {
    let input = [episode("e1", index: 1), episode("e2", index: 2), episode("e3", index: 3)]
    let order = input.sortedByEpisodeOrder().map(\.index)
    #expect(order == [1, 2, 3])
}

@Test func emptyInputReturnsEmpty() {
    #expect([MediaItem]().sortedByEpisodeOrder().isEmpty)
}
