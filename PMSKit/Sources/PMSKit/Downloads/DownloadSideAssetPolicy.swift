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
    /// transfer actually downloads, never from the media's first part (#495). An out-of-range media
    /// index keeps the historical first-media fallback; an out-of-range part index selects nothing,
    /// exactly like the transfer, which fails rather than downloading another part.
    ///
    /// A non-nil `sourcePartID` (the completed-row repair passes the persisted one) selects that
    /// part by identity, wherever a media reorder has moved it, and nothing when it is gone (#503).
    public static func selectedPlexBIFPart(from item: MediaItem, mediaIndex: Int, partIndex: Int,
                                           sourcePartID: Int? = nil) -> Part? {
        if sourcePartID != nil {
            guard let part = plexRepairPart(from: item, mediaIndex: mediaIndex, partIndex: partIndex,
                                            sourcePartID: sourcePartID),
                  part.hasStandardDefinitionBIFIndex else { return nil }
            return part
        }
        guard let media = item.media, !media.isEmpty else { return nil }
        let selectedMedia = media.indices.contains(mediaIndex) ? media[mediaIndex] : media[0]
        guard selectedMedia.part.indices.contains(partIndex) else { return nil }
        let part = selectedMedia.part[partIndex]
        guard part.hasStandardDefinitionBIFIndex else { return nil }
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

    /// The chapters a completed row should persist after a successful source refresh, or nil when
    /// the refresh teaches nothing (#504). The completed-row inventory is derived from the saved
    /// chapters, so a row saved before the server had chapter thumbnails would never owe them.
    ///
    /// - A saved list with no thumbnail is replaced by the refreshed list when that list has one.
    ///   No chapter image can be cached against a list without thumbnails, so no cached image's
    ///   index is invalidated.
    /// - A saved list that has thumbnails gains the refreshed thumbnails it lacks, only when both
    ///   lists have the same chapters (count and start offsets); otherwise it is kept, because the
    ///   cached images are keyed by its indexes.
    public static func learnedOfflineChapters(saved: [OfflineChapter]?,
                                              current: [Chapter]?) -> [OfflineChapter]? {
        let refreshed = (current ?? []).map(OfflineChapter.init)
        guard refreshed.contains(where: { hasThumb($0.thumb) }) else { return nil }
        let savedList = saved ?? []
        if !savedList.contains(where: { hasThumb($0.thumb) }) {
            return refreshed == savedList ? nil : refreshed
        }
        guard savedList.count == refreshed.count,
              zip(savedList, refreshed).allSatisfy({ $0.startTimeOffset == $1.startTimeOffset })
        else { return nil }
        let merged = zip(savedList, refreshed).map { savedChapter, refreshedChapter -> OfflineChapter in
            guard !hasThumb(savedChapter.thumb), hasThumb(refreshedChapter.thumb) else { return savedChapter }
            var chapter = savedChapter
            chapter.thumb = refreshedChapter.thumb
            return chapter
        }
        return merged == savedList ? nil : merged
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func hasThumb(_ value: String?) -> Bool {
        value.map { !isBlank($0) } ?? false
    }
}
