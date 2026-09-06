import Foundation

/// Concrete AVPlayer buffering settings selected by `PlaybackBufferingPolicy`.
public struct PlaybackBufferingConfiguration: Sendable, Equatable {
    public let preferredForwardBufferSeconds: Double
    public let automaticallyWaitsToMinimizeStalling: Bool
    public let canUseNetworkResourcesForLiveStreamingWhilePaused: Bool
    public let usesShortRemoteHLSBuffer: Bool

    public init(preferredForwardBufferSeconds: Double,
                automaticallyWaitsToMinimizeStalling: Bool,
                canUseNetworkResourcesForLiveStreamingWhilePaused: Bool,
                usesShortRemoteHLSBuffer: Bool) {
        self.preferredForwardBufferSeconds = preferredForwardBufferSeconds
        self.automaticallyWaitsToMinimizeStalling = automaticallyWaitsToMinimizeStalling
        self.canUseNetworkResourcesForLiveStreamingWhilePaused = canUseNetworkResourcesForLiveStreamingWhilePaused
        self.usesShortRemoteHLSBuffer = usesShortRemoteHLSBuffer
    }
}

/// Shared playback buffering policy for every `PlaybackController` load path.
///
/// Normal VOD playback (Plex HLS, static/direct streams, and initial Jellyfin/Emby remote HLS)
/// keeps an airplane-safe forward cushion. The short target is reserved only for explicit
/// out-of-buffer remote-HLS seek reopens, where the backend may mint segments around realtime and a
/// deep first-frame target can wedge resume.
public enum PlaybackBufferingPolicy {
    /// Desired steady-state VOD cushion for normal playback/reloads.
    public static let steadyStateForwardBufferSeconds: Double = 300
    /// Recovery/reopen target for explicit out-of-buffer remote-HLS seeks.
    public static let remoteHLSSeekReopenForwardBufferSeconds: Double = 12

    /// True when the stream URL is a server-encoded HLS playlist (`.m3u8`). Plex serves ALL
    /// playback — Direct Play / Direct Stream included — as a `start.m3u8` transcode-session
    /// playlist, which has no `EXT-X-ENDLIST` while the session runs, so AVPlayer treats it as
    /// live-ish and stops loading while paused unless
    /// `canUseNetworkResourcesForLiveStreamingWhilePaused` is set. Jellyfin/Emby direct lanes
    /// are progressive file URLs (true VOD) and correctly return false here. (#195 live test)
    public static func isServerEncodedHLSPlaylist(url: URL?) -> Bool {
        url?.pathExtension.lowercased() == "m3u8"
    }

    public static func configuration(isRemoteServerEncodedHLS: Bool,
                                     preferShortRemoteHLSBuffer: Bool,
                                     isEmbyVideoCopyHLS: Bool = false) -> PlaybackBufferingConfiguration {
        let usesShortRemoteHLSBuffer = isRemoteServerEncodedHLS && preferShortRemoteHLSBuffer
        let preferredForwardBufferSeconds = usesShortRemoteHLSBuffer
            ? remoteHLSSeekReopenForwardBufferSeconds
            : steadyStateForwardBufferSeconds

        return PlaybackBufferingConfiguration(
            preferredForwardBufferSeconds: preferredForwardBufferSeconds,
            // With automatic waiting disabled, starvation can leave AVPlayer paused at
            // rate zero. Keep automatic recovery for Emby copy reopens without changing
            // their short buffer target, delivery URL, audio conversion, or pause loading.
            automaticallyWaitsToMinimizeStalling: !usesShortRemoteHLSBuffer || isEmbyVideoCopyHLS,
            canUseNetworkResourcesForLiveStreamingWhilePaused: isRemoteServerEncodedHLS && !usesShortRemoteHLSBuffer,
            usesShortRemoteHLSBuffer: usesShortRemoteHLSBuffer)
    }
}
