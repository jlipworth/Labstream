import Foundation

/// Shared ordering for the Offline downloads list.
///
/// Episodes are persisted with their episode title as `DownloadRecord.title`, but the library should
/// sort them by their series context when offline metadata is available: show title, season number,
/// episode number, then episode title. Legacy rows without metadata keep the historical title sort.
public enum OfflineDownloadSort {
    public static func sorted(_ records: [DownloadRecord]) -> [DownloadRecord] {
        // Build each locale-folded key once. The offline list refreshes at live-download cadence,
        // and constructing SortKey inside the comparator repeated expensive String folding during
        // every comparison, which showed up as main-thread CPU while multiple Range downloads ran.
        records.enumerated()
            .map { keyedRecord in
                KeyedRecord(record: keyedRecord.element,
                            key: SortKey(record: keyedRecord.element,
                                         originalOffset: keyedRecord.offset))
            }
            .sorted { $0.key < $1.key }
            .map(\.record)
    }

    private struct KeyedRecord {
        let record: DownloadRecord
        let key: SortKey
    }

    private struct SortKey: Comparable {
        let primaryTitle: String
        let typeRank: Int
        let season: Int
        let episode: Int
        let leafTitle: String
        let originalOffset: Int
        let ratingKey: String

        init(record: DownloadRecord, originalOffset: Int) {
            let metadata = record.metadata
            let isEpisode = metadata?.type.lowercased() == "episode"
            primaryTitle = Self.normalized(isEpisode ? (metadata?.grandparentTitle ?? record.title)
                                                     : record.title)
            typeRank = isEpisode ? 0 : 1
            season = isEpisode ? (metadata?.parentIndex ?? Int.max) : Int.max
            episode = isEpisode ? (metadata?.index ?? Int.max) : Int.max
            leafTitle = Self.normalized(record.title)
            self.originalOffset = originalOffset
            ratingKey = record.ratingKey
        }

        static func < (lhs: SortKey, rhs: SortKey) -> Bool {
            if lhs.primaryTitle != rhs.primaryTitle { return lhs.primaryTitle < rhs.primaryTitle }
            if lhs.typeRank != rhs.typeRank { return lhs.typeRank < rhs.typeRank }
            if lhs.season != rhs.season { return lhs.season < rhs.season }
            if lhs.episode != rhs.episode { return lhs.episode < rhs.episode }
            if lhs.leafTitle != rhs.leafTitle { return lhs.leafTitle < rhs.leafTitle }
            if lhs.ratingKey != rhs.ratingKey { return lhs.ratingKey < rhs.ratingKey }
            return lhs.originalOffset < rhs.originalOffset
        }

        private static func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        }
    }
}
