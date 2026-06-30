import Foundation

/// Pure storage preflight estimates for download media and sidecar caches.
public enum DownloadStorageEstimatePolicy {
    public enum MediaSource: Equatable, Sendable {
        /// Byte-for-byte source/static-version transfer, or remux whose output is source-sized.
        case sourceFile
        /// Transcoded output estimated from duration × target bitrate.
        case transcode(videoBitrateBps: Int)
    }

    public static func estimatedMediaBytes(source: MediaSource,
                                           sourcePartBytes: Int?,
                                           durationMs: Int?) -> Int? {
        switch source {
        case .sourceFile:
            return sourcePartBytes
        case .transcode(let videoBitrateBps):
            return TranscodeSizeEstimator.bytes(durationMs: durationMs,
                                                videoBitrateBps: videoBitrateBps)
        }
    }

    /// Rough pre-download estimate of a backend's thumbnail-cache side assets. Plex BIF + Jellyfin
    /// tile sheets are duration-proportional scrub-preview data of comparable magnitude and share
    /// one model. Every backend may also cache per-chapter images, bounded by source chapter count.
    public static func estimatedSideAssetBytes(durationMs: Int?,
                                               backend: DownloadBackendKind,
                                               chapterImageCount: Int) -> Int {
        let chapterImages = estimatedChapterImageBytes(chapterImageCount: chapterImageCount)
        switch backend {
        case .jellyfin, .plex:
            return JellyfinTrickPlayOfflineCachePlanner.estimatedTileBytes(durationMs: durationMs) + chapterImages
        case .emby:
            return chapterImages
        }
    }

    public static func estimatedChapterImageBytes(chapterImageCount: Int) -> Int {
        max(0, chapterImageCount) * 30_000
    }

    public static func totalBytes(mediaBytes: Int?, sideAssetBytes: Int) -> Int? {
        guard sideAssetBytes > 0 else { return mediaBytes }
        return (mediaBytes ?? 0) + sideAssetBytes
    }

    /// Full preflight estimate for a selected download source.
    ///
    /// This composes the media-byte estimate (source part size vs. duration×bitrate transcode
    /// estimate) with the side assets that the offline download pipeline also caches. Text-subtitle
    /// sidecars are intentionally not estimated here: they are small, backend-variable, and accounted
    /// from disk after caching through `DownloadRecord.sideAssetBytes`.
    public static func estimatedTotalBytes(for item: MediaItem,
                                           choice: DownloadIntentChoice,
                                           backend: DownloadBackendKind,
                                           mediaIndex: Int = 0,
                                           partIndex: Int = 0) -> Int? {
        let media = item.media.flatMap { media in
            media.indices.contains(mediaIndex) ? media[mediaIndex] : nil
        }
        let part = media.flatMap { media in
            media.part.indices.contains(partIndex) ? media.part[partIndex] : nil
        }
        let mediaBytes = estimatedMediaBytes(
            source: DownloadPresetPolicy.storageEstimateMediaSource(for: choice),
            sourcePartBytes: part?.size,
            durationMs: item.duration)
        let chapterImageCount = item.chapters?.filter { $0.thumb?.isEmpty == false }.count ?? 0
        let sideAssetBytes = estimatedSideAssetBytes(
            durationMs: item.duration,
            backend: backend,
            chapterImageCount: chapterImageCount)
        return totalBytes(mediaBytes: mediaBytes, sideAssetBytes: sideAssetBytes)
    }
}
