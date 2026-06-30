import Foundation

/// Pure selection helper for the media/part tuple a download request targets.
///
/// The app receives a `MediaItem` plus UI-chosen `mediaIndex`/`partIndex` in the download sheet,
/// backend retry paths, and debug probes. This policy keeps the nil-tolerant index selection and
/// MediaBrowser `MediaSourceId` extraction in one tested place, instead of hand-rolling it in every
/// backend adapter.
public enum DownloadMediaSelectionPolicy {
    public struct Selection: Sendable {
        public let mediaIndex: Int
        public let partIndex: Int
        public let media: Media?
        public let part: Part?
        public let mediaSourceID: String?

        public init(mediaIndex: Int, partIndex: Int, media: Media?, part: Part?, mediaSourceID: String?) {
            self.mediaIndex = mediaIndex
            self.partIndex = partIndex
            self.media = media
            self.part = part
            self.mediaSourceID = mediaSourceID
        }
    }

    public static func selection(item: MediaItem, mediaIndex: Int, partIndex: Int) -> Selection {
        let media = item.media.flatMap { mediaItems in
            mediaItems.indices.contains(mediaIndex) ? mediaItems[mediaIndex] : nil
        }
        let part = media.flatMap { selectedMedia in
            selectedMedia.part.indices.contains(partIndex) ? selectedMedia.part[partIndex] : nil
        }
        return Selection(mediaIndex: mediaIndex,
                         partIndex: partIndex,
                         media: media,
                         part: part,
                         mediaSourceID: mediaSourceID(media: media, part: part))
    }

    /// Extract a MediaBrowser MediaSource id from synthesized part keys such as
    /// `.../media/{mediaSourceId}`. Prefer the selected part, then fall back to other parts on the
    /// chosen media. This is only a hint; Emby/Jellyfin PlaybackInfo decisions remain authoritative.
    public static func mediaSourceID(media: Media?, part: Part?) -> String? {
        let keys = [part?.key] + (media?.part.map(\.key) ?? [])
        for key in keys.compactMap({ $0 }) {
            guard let marker = key.range(of: "/media/") else { continue }
            let source = String(key[marker.upperBound...])
            if !source.isEmpty { return source }
        }
        return nil
    }

    public static func containerExtension(selection: Selection, fallback: String = "mp4") -> String {
        let raw = selection.part?.container ?? selection.media?.container ?? fallback
        return raw.isEmpty ? fallback : raw
    }
}
