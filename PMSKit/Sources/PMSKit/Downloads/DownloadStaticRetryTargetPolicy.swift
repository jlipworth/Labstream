import Foundation

public enum DownloadStaticRetryIntent: Equatable, Sendable {
    case original
    case existingVersion
    /// A persisted exact Part id no longer exists in refreshed server metadata. Never fall back to
    /// the old array index: it may now address the raw source or a different rendered version.
    case unavailable
}

public struct DownloadStaticRetryTarget: Equatable, Sendable {
    public var intent: DownloadStaticRetryIntent
    public var mediaIndex: Int
    public var partIndex: Int

    public init(intent: DownloadStaticRetryIntent, mediaIndex: Int, partIndex: Int) {
        self.intent = intent
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
    }
}

/// Pure source-selection policy for retrying static byte-range rows after metadata refresh.
///
/// Static retries must find the same source part when the persisted `sourcePartID` is present;
/// otherwise they fall back to the original call-site indices while preserving whether the row is a
/// true original or a server-prepared/existing version. The app layer maps the returned intent to
/// its local `DownloadChoice` enum.
public enum DownloadStaticRetryTargetPolicy {
    public static func target(metadata: OfflineMetadata?,
                              item: MediaItem,
                              fallbackMediaIndex: Int,
                              fallbackPartIndex: Int) -> DownloadStaticRetryTarget {
        if let partID = metadata?.sourcePartID {
            for (mediaIndex, media) in (item.media ?? []).enumerated() {
                if let partIndex = media.part.firstIndex(where: { $0.id == partID }) {
                    let isPrimaryOriginal = mediaIndex == 0 && metadata?.isServerPreparedVersion != true
                    return DownloadStaticRetryTarget(intent: isPrimaryOriginal ? .original : .existingVersion,
                                                     mediaIndex: mediaIndex,
                                                     partIndex: partIndex)
                }
            }
            return DownloadStaticRetryTarget(intent: .unavailable,
                                             mediaIndex: fallbackMediaIndex,
                                             partIndex: fallbackPartIndex)
        }
        let isPrepared = metadata?.isServerPreparedVersion == true || (metadata?.mediaIndex ?? 0) > 0
        return DownloadStaticRetryTarget(intent: isPrepared ? .existingVersion : .original,
                                         mediaIndex: fallbackMediaIndex,
                                         partIndex: fallbackPartIndex)
    }
}
