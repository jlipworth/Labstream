import Testing
@testable import PlexKit

// Three chapters starting at 0ms, 12_000ms, 28_000ms.
private let chapters: [Chapter] = [
    Chapter(id: 1, tag: "Cold Open", startTimeOffset: 0,      endTimeOffset: 12_000),
    Chapter(id: 2, tag: "The Heist",  startTimeOffset: 12_000, endTimeOffset: 28_000),
    Chapter(id: 3, tag: "Aftermath",  startTimeOffset: 28_000, endTimeOffset: 41_000),
]

@Test func midChapterReturnsThatChapter() {
    #expect(chapters.indexOfChapter(at: 15_000) == 1)
}

@Test func exactBoundaryReturnsThatChapter() {
    #expect(chapters.indexOfChapter(at: 12_000) == 1)
}

@Test func firstChapterStartReturnsZero() {
    #expect(chapters.indexOfChapter(at: 0) == 0)
}

@Test func pastLastStartReturnsLast() {
    #expect(chapters.indexOfChapter(at: 999_999) == 2)
}

@Test func beforeFirstChapterReturnsNil() {
    let later = [Chapter(id: 1, tag: "Late", startTimeOffset: 5_000, endTimeOffset: 9_000)]
    #expect(later.indexOfChapter(at: 1_000) == nil)
}

@Test func emptyListReturnsNil() {
    #expect([Chapter]().indexOfChapter(at: 0) == nil)
}

@Test func skipsChaptersWithNilStart() {
    let mixed = [
        Chapter(id: 1, tag: "A", startTimeOffset: nil),
        Chapter(id: 2, tag: "B", startTimeOffset: 10_000),
    ]
    #expect(mixed.indexOfChapter(at: 12_000) == 1)
}
