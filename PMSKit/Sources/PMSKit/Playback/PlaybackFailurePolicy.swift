import Foundation

/// Source of an AVPlayer failure signal. Kept pure/testable so PlaybackController can make
/// conservative decisions without depending on AVFoundation types in unit tests.
public enum PlaybackFailureSource: String, Sendable, Equatable {
    case itemStatusFailed = "item_status_failed"
    case failedToPlayToEnd = "failed_to_play_to_end"
    case stallWatchdog = "stall_watchdog"
    case playerFailure = "player_failure"
}

/// Coarse playback path for failure policy. `remoteHLS` means a non-Plex backend already handed
/// the app a concrete HLS URL and can reopen it; today that is Jellyfin remote playback.
public enum PlaybackFailurePath: String, Sendable, Equatable {
    case remoteHLS = "remote_hls"
    case other = "other"
}

public struct PlaybackFailureSnapshot: Sendable, Equatable {
    public let source: PlaybackFailureSource
    public let path: PlaybackFailurePath
    public let isCurrentItem: Bool
    public let isItemReadyToPlay: Bool
    public let isPlayerPlaying: Bool
    public let bufferedAheadSeconds: Double
    public let notificationErrorCode: Int?
    public let itemErrorCode: Int?
    public let playerErrorCode: Int?
    public let ignoredRecoverableFailureCount: Int

    public init(source: PlaybackFailureSource,
                path: PlaybackFailurePath,
                isCurrentItem: Bool,
                isItemReadyToPlay: Bool,
                isPlayerPlaying: Bool,
                bufferedAheadSeconds: Double,
                notificationErrorCode: Int?,
                itemErrorCode: Int?,
                playerErrorCode: Int?,
                ignoredRecoverableFailureCount: Int = 0) {
        self.source = source
        self.path = path
        self.isCurrentItem = isCurrentItem
        self.isItemReadyToPlay = isItemReadyToPlay
        self.isPlayerPlaying = isPlayerPlaying
        self.bufferedAheadSeconds = bufferedAheadSeconds
        self.notificationErrorCode = notificationErrorCode
        self.itemErrorCode = itemErrorCode
        self.playerErrorCode = playerErrorCode
        self.ignoredRecoverableFailureCount = ignoredRecoverableFailureCount
    }
}

public enum PlaybackFailureAction: String, Sendable, Equatable {
    case surface = "surface"
    case ignoreStaleItem = "ignore_stale_item"
    case ignoreRecoverableBufferedRemoteHLS = "ignore_recoverable_buffered_remote_hls"
}

public enum PlaybackFailurePolicy {
    /// AVFoundation can emit `failedToPlayToEnd` for a Jellyfin HLS item immediately after it has
    /// reached ready/playing with media buffered. Treat only that narrow first signal as
    /// non-fatal: stale items are always ignored, status failures still surface, and repeated or
    /// unbuffered failures surface so we do not hide real playback errors.
    public static func action(for snapshot: PlaybackFailureSnapshot) -> PlaybackFailureAction {
        guard snapshot.isCurrentItem else { return .ignoreStaleItem }
        guard snapshot.source == .failedToPlayToEnd else { return .surface }
        guard snapshot.path == .remoteHLS,
              snapshot.isItemReadyToPlay,
              snapshot.isPlayerPlaying,
              snapshot.bufferedAheadSeconds >= 2,
              snapshot.notificationErrorCode == -66681,
              snapshot.ignoredRecoverableFailureCount == 0 else {
            return .surface
        }
        return .ignoreRecoverableBufferedRemoteHLS
    }
}
