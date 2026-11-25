import Foundation

public struct ParsedChapterImageKey: Equatable, Sendable {
    public var itemID: String
    public var index: Int
    public var tag: String?

    public init(itemID: String, index: Int, tag: String?) {
        self.itemID = itemID
        self.index = index
        self.tag = tag
    }
}

/// Pure side-asset decisions for offline downloads.
///
/// Fetching, auth, atomic writes, and store mutation stay in the app layer. This policy pins the
/// reusable selection/parsing rules that decide which side assets are worth attempting offline.
public enum DownloadSideAssetPolicy {
    /// Artwork reference for the Offline tab's small portrait tile. Episodes prefer show/season
    /// posters before the episode still/backdrop to avoid stretching landscape stills into portrait.
    /// An empty or whitespace-only field is absent, so the next valid field is used: a Plex movie
    /// with `thumb == ""` and a valid `art` still gets a poster (#504).
    public static func offlinePosterRef(for item: MediaItem) -> String? {
        let candidates = item.kind == .episode
            ? [item.grandparentThumb, item.parentThumb, item.thumb, item.art]
            : [item.thumb, item.art]
        return candidates.lazy.compactMap { $0 }.first { !isBlank($0) }
    }

    /// The Plex part a completed-row repair (BIF or text subtitles) must use: the part the row
    /// downloaded. Plex can reorder an item's media after the download, so a persisted
    /// `sourcePartID` is resolved by identity, and an ID the refreshed item no longer has selects
    /// nothing rather than another part (#503). Only a legacy row that stored no ID falls back to
    /// `media[mediaIndex].part[partIndex]`.
    public static func plexRepairPart(from item: MediaItem, mediaIndex: Int, partIndex: Int,
                                      sourcePartID: Int?) -> Part? {
        guard let media = item.media, !media.isEmpty else { return nil }
        if let sourcePartID {
            return media.lazy.flatMap(\.part).first { $0.id == sourcePartID }
        }
        guard media.indices.contains(mediaIndex),
              media[mediaIndex].part.indices.contains(partIndex) else { return nil }
        return media[mediaIndex].part[partIndex]
    }

    /// The Plex part whose BIF trick-play index belongs to a download of `part[partIndex]` of
    /// `media[mediaIndex]`. The BIF describes one part's file, so it must come from the part the
    /// transfer actually downloads, never from the media's first part (#495), and it is selected
    /// exactly like the subtitle repair selects its part (`plexRepairPart`): a non-nil
    /// `sourcePartID` (the completed-row repair passes the persisted one) selects that part by
    /// identity, wherever a media reorder has moved it, and nothing when it is gone (#503). Without
    /// an ID both saved indexes must resolve: a media or part index the item no longer has selects
    /// nothing, never `media[0]` or another file (the transfer fails on the same indexes rather
    /// than downloading another part).
    public static func selectedPlexBIFPart(from item: MediaItem, mediaIndex: Int, partIndex: Int,
                                           sourcePartID: Int? = nil) -> Part? {
        guard let part = plexRepairPart(from: item, mediaIndex: mediaIndex, partIndex: partIndex,
                                        sourcePartID: sourcePartID),
              part.hasStandardDefinitionBIFIndex else { return nil }
        return part
    }

    /// Parse a synthetic `<scheme>://item/{itemId}/Chapter/{index}?tag=` chapter-image key
    /// (Jellyfin or Emby). Mirrors the online thumbnail providers.
    public static func parsedSyntheticChapterImageKey(_ imagePath: String,
                                                      scheme: String) -> ParsedChapterImageKey? {
        guard let url = URL(string: imagePath), url.scheme == scheme, url.host == "item" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "Chapter", let index = Int(parts[2]) else { return nil }
        let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "tag" }?.value
        return ParsedChapterImageKey(itemID: parts[0], index: index, tag: tag)
    }

    /// Two chapter start offsets (milliseconds) within this distance name the same chapter. A
    /// server rescan can move a boundary by a frame or two; real chapters are seconds apart.
    public static let chapterStartMatchTolerance = 1_000

    /// The chapters a completed row should persist after a successful source refresh, or nil when
    /// the refresh teaches nothing (#504). The completed-row inventory is derived from the saved
    /// chapters, so a row saved before the server had chapter thumbnails would never owe them.
    ///
    /// - An empty saved list adopts the refreshed list whole, with or without thumbnails, so the
    ///   row gains the chapter titles and seek times even when no image can be scheduled.
    /// - A non-empty saved list is the row's timeline and is never replaced: its titles, offsets
    ///   and indexes stay, and the cached chapter images are keyed by those indexes. A saved
    ///   chapter without a thumbnail gains the thumbnail of the refreshed chapter that matches it:
    ///   the one at the same index with the same start (within `chapterStartMatchTolerance`, or
    ///   both without a start), else the only refreshed chapter that starts within the tolerance.
    ///   A rescan that drops, adds or retimes chapters teaches only the chapters that still match.
    public static func learnedOfflineChapters(saved: [OfflineChapter]?,
                                              current: [Chapter]?) -> [OfflineChapter]? {
        let refreshed = (current ?? []).map(OfflineChapter.init)
        let savedList = saved ?? []
        if savedList.isEmpty {
            return refreshed.isEmpty ? nil : refreshed
        }
        let merged = savedList.enumerated().map { index, savedChapter -> OfflineChapter in
            guard !hasThumb(savedChapter.thumb),
                  let match = matchingChapter(for: savedChapter, at: index, in: refreshed),
                  hasThumb(match.thumb) else { return savedChapter }
            var chapter = savedChapter
            chapter.thumb = match.thumb
            return chapter
        }
        return merged == savedList ? nil : merged
    }

    private static func matchingChapter(for saved: OfflineChapter, at index: Int,
                                        in refreshed: [OfflineChapter]) -> OfflineChapter? {
        func sameStart(_ lhs: Int?, _ rhs: Int?) -> Bool {
            switch (lhs, rhs) {
            case (nil, nil): return true
            case let (lhs?, rhs?): return abs(lhs - rhs) <= chapterStartMatchTolerance
            default: return false
            }
        }
        if refreshed.indices.contains(index),
           sameStart(saved.startTimeOffset, refreshed[index].startTimeOffset) {
            return refreshed[index]
        }
        guard let start = saved.startTimeOffset else { return nil }
        let candidates = refreshed.filter {
            guard let other = $0.startTimeOffset else { return false }
            return abs(other - start) <= chapterStartMatchTolerance
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasThumb(_ value: String?) -> Bool {
        value.map { !isBlank($0) } ?? false
    }
}
