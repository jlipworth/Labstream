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

    public static func configuration(isRemoteServerEncodedHLS: Bool,
                                     preferShortRemoteHLSBuffer: Bool) -> PlaybackBufferingConfiguration {
        let usesShortRemoteHLSBuffer = isRemoteServerEncodedHLS && preferShortRemoteHLSBuffer
        let preferredForwardBufferSeconds = usesShortRemoteHLSBuffer
            ? remoteHLSSeekReopenForwardBufferSeconds
            : steadyStateForwardBufferSeconds

        return PlaybackBufferingConfiguration(
            preferredForwardBufferSeconds: preferredForwardBufferSeconds,
            automaticallyWaitsToMinimizeStalling: !usesShortRemoteHLSBuffer,
            canUseNetworkResourcesForLiveStreamingWhilePaused: isRemoteServerEncodedHLS && !usesShortRemoteHLSBuffer,
            usesShortRemoteHLSBuffer: usesShortRemoteHLSBuffer)
    }
}
