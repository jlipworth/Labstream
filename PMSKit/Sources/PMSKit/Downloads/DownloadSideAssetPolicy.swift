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
    public static func offlinePosterRef(for item: MediaItem) -> String? {
        if item.kind == .episode {
            return item.grandparentThumb ?? item.parentThumb ?? item.thumb ?? item.art
        }
        return item.thumb ?? item.art
    }

    /// The Plex part whose BIF trick-play index belongs to a download of `part[partIndex]` of
    /// `media[mediaIndex]`. The BIF describes one part's file, so it must come from the part the
    /// transfer actually downloads, never from the media's first part (#495). An out-of-range media
    /// index keeps the historical first-media fallback; an out-of-range part index selects nothing,
    /// exactly like the transfer, which fails rather than downloading another part.
    public static func selectedPlexBIFPart(from item: MediaItem, mediaIndex: Int, partIndex: Int) -> Part? {
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

}
