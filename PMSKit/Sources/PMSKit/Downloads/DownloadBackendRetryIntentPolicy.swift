import Foundation

/// Pure retry rehydration for backend-specific failed/paused rows.
///
/// The app layer still checks backend sign-in, releases stale in-flight slots, and starts the async
/// backend download. This policy owns the durable metadata-to-user-intent mapping so retries after
/// relaunch keep the same lane semantics: Jellyfin compatible-remux remains compatible, Emby
/// server-prepared rows retry the exact converted source, and global Original-quality labels are
/// normalized for MediaBrowser transcode requests.
public struct DownloadBackendRetryIntent: Sendable {
    public let item: MediaItem
    public let choice: DownloadIntentChoice
    public let mediaIndex: Int
    public let partIndex: Int
    public let mediaSourceIDOverride: String?
    public let audioStreamIndex: Int?

    public init(item: MediaItem,
                choice: DownloadIntentChoice,
                mediaIndex: Int,
                partIndex: Int,
                mediaSourceIDOverride: String?,
                audioStreamIndex: Int? = nil) {
        self.item = item
        self.choice = choice
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
        self.mediaSourceIDOverride = mediaSourceIDOverride
        self.audioStreamIndex = audioStreamIndex
    }
}

public enum DownloadBackendRetryIntentPolicy {
    /// The optimize target a failed Plex row must retry with: the user's persisted requested
    /// target (#194), never the global default preset. `nil` when the row recorded no target
    /// (a true original or legacy row), in which case the caller keeps its re-probe path.
    public static func plexPersistedOptimizeTarget(for record: DownloadRecord) -> String? {
        guard let metadata = record.metadata,
              metadata.resolvedBackendKind(ratingKey: record.ratingKey) == .plex,
              let target = metadata.optimizeTargetName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !target.isEmpty else {
            return nil
        }
        return target
    }

    public static func jellyfinIntent(for record: DownloadRecord,
                                      fallbackItemID: String,
                                      fallbackOriginalIsLocallyPlayable: Bool) -> DownloadBackendRetryIntent {
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: fallbackItemID,
                         title: record.title,
                         type: "movie")
        let choice: DownloadIntentChoice
        if let targetName = metadata?.optimizeTargetName, !targetName.isEmpty {
            choice = .optimize(targetName: DownloadPresetPolicy.jellyfinDownloadPreset(named: targetName))
        } else if metadata?.resolvedDownloadLane() == .compatibleRemux {
            // Persisted compatible-remux rows have no optimizeTargetName. Without the lane
            // discriminator they would retry as `.original` and silently drop the user's intent.
            choice = .optimizeCompatible
        } else if metadata != nil {
            // Stored rows know the original user intent. `makeMediaItem()` intentionally does not
            // rehydrate full MediaSource/Part arrays, so deriving this from a missing part after a
            // relaunch would incorrectly turn original retries into optimized transcodes.
            choice = .original
        } else if fallbackOriginalIsLocallyPlayable {
            choice = .original
        } else {
            choice = .optimize(targetName: DownloadPresetPolicy.jellyfinDefaultDownloadPreset)
        }
        return DownloadBackendRetryIntent(item: item,
                                          choice: choice,
                                          mediaIndex: metadata?.mediaIndex ?? 0,
                                          partIndex: metadata?.partIndex ?? 0,
                                          mediaSourceIDOverride: metadata?.mediaSourceID,
                                          audioStreamIndex: metadata?.audioStreamIndex)
    }

    public static func embyIntent(for record: DownloadRecord,
                                  fallbackItemID: String) -> DownloadBackendRetryIntent {
        let metadata = record.metadata
        let item = metadata?.makeMediaItem()
            ?? MediaItem(ratingKey: fallbackItemID,
                         title: record.title,
                         type: "movie")
        let choice: DownloadIntentChoice
        if metadata?.isServerPreparedVersion == true,
           let sourceID = metadata?.mediaSourceID,
           !sourceID.isEmpty {
            // A converted/reused Emby MediaSource must be retried byte-for-byte via the same source,
            // not downgraded to `.original` and re-badged as Original.
            choice = .existingVersion
        } else if let targetName = metadata?.optimizeTargetName, !targetName.isEmpty {
            choice = .optimize(targetName: DownloadPresetPolicy.jellyfinDownloadPreset(named: targetName))
        } else if metadata?.resolvedDownloadLane() == .compatibleRemux {
            choice = .optimizeCompatible
        } else {
            choice = .original
        }
        return DownloadBackendRetryIntent(item: item,
                                          choice: choice,
                                          mediaIndex: metadata?.mediaIndex ?? 0,
                                          partIndex: metadata?.partIndex ?? 0,
                                          mediaSourceIDOverride: metadata?.mediaSourceID,
                                          audioStreamIndex: metadata?.audioStreamIndex)
    }
}
