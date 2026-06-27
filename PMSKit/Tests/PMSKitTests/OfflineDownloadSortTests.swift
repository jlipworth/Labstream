import Foundation
import Testing
@testable import PMSKit

@Suite("Offline download sort")
struct OfflineDownloadSortTests {

    @Test("episodes sort by show season episode before episode title")
    func episodesSortByShowSeasonEpisode() {
        let rows = [
            movie("Project Hail Mary"),
            episode(show: "The Crown", season: 1, episode: 2, title: "Hyde Park Corner"),
            movie("The Matrix"),
            episode(show: "The Crown", season: 1, episode: 1, title: "Wolferton Splash"),
            movie("A Serious Man"),
        ]

        let sorted = OfflineDownloadSort.sorted(rows).map(\.title)

        #expect(sorted == [
            "A Serious Man",
            "Project Hail Mary",
            "Wolferton Splash",
            "Hyde Park Corner",
            "The Matrix",
        ])
    }

    @Test("missing episode indices sort after known season episode numbers")
    func missingEpisodeIndicesSortAfterKnownNumbers() {
        let rows = [
            episode(show: "Show", season: nil, episode: nil, title: "Special"),
            episode(show: "Show", season: 2, episode: 1, title: "Premiere"),
            episode(show: "Show", season: 1, episode: 10, title: "Finale"),
        ]

        let sorted = OfflineDownloadSort.sorted(rows).map(\.title)

        #expect(sorted == ["Finale", "Premiere", "Special"])
    }

    @Test("legacy rows without metadata keep title ordering")
    func legacyRowsWithoutMetadataKeepTitleOrdering() {
        let rows = [record(title: "zeta", metadata: nil),
                    record(title: "Alpha", metadata: nil),
                    record(title: "beta", metadata: nil)]

        #expect(OfflineDownloadSort.sorted(rows).map(\.title) == ["Alpha", "beta", "zeta"])
    }

    private func movie(_ title: String) -> DownloadRecord {
        record(title: title,
               metadata: OfflineMetadata(ratingKey: "movie:\(title)", title: title, type: "movie"))
    }

    private func episode(show: String,
                         season: Int?,
                         episode: Int?,
                         title: String) -> DownloadRecord {
        record(title: title,
               metadata: OfflineMetadata(ratingKey: "episode:\(show):\(season ?? -1):\(episode ?? -1):\(title)",
                                         title: title,
                                         type: "episode",
                                         grandparentTitle: show,
                                         parentIndex: season,
                                         index: episode))
    }

    private func record(title: String, metadata: OfflineMetadata?) -> DownloadRecord {
        DownloadRecord(ratingKey: metadata?.ratingKey ?? "legacy:\(title)",
                       title: title,
                       localURL: URL(fileURLWithPath: "/tmp/\(title).mp4"),
                       metadata: metadata)
    }
}
