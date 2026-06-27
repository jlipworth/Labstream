import Foundation

/// Shared playback-request policy for Jellyfin/Emby. Inputs are the app's quality ladder value
/// in kilobits per second plus an optional resume offset in milliseconds; outputs are the explicit
/// units those backends expect in PlaybackInfo/stream requests.
public struct MediaBrowserPlaybackQualityPolicy: Sendable, Equatable {
    public let maxVideoBitrateKbps: Int
    public let maxStreamingBitrateBps: Int
    public let maxWidth: Int?
    public let maxHeight: Int?
    public let audioBitrateBps: Int?

    public init(maxVideoBitrateKbps: Int) {
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.maxStreamingBitrateBps = maxVideoBitrateKbps <= 0 ? 200_000_000 : maxVideoBitrateKbps * 1_000
        let resolutionCap = Self.resolutionCap(forBitrateKbps: maxVideoBitrateKbps)
        self.maxWidth = resolutionCap?.width
        self.maxHeight = resolutionCap?.height
        self.audioBitrateBps = Self.audioBitrate(forBitrateKbps: maxVideoBitrateKbps)
    }

    public static func startTicks(resumeOffsetMs: Int?) -> Int? {
        resumeOffsetMs.map { $0 * 10_000 }
    }

    public static func resolutionCap(forBitrateKbps kbps: Int) -> (width: Int, height: Int)? {
        switch kbps {
        case 1...4_000:
            return (1280, 720)
        case 4_001...20_000:
            return (1920, 1080)
        case 20_001...40_000:
            return (3840, 2160)
        default:
            return nil
        }
    }

    public static func audioBitrate(forBitrateKbps kbps: Int) -> Int? {
        switch kbps {
        case 1...4_000:
            return 256_000
        case 4_001...20_000:
            return 640_000
        default:
            return nil
        }
    }
}

/// Shared interpretation for `/Videos/ActiveEncodings` cleanup. A transport failure or auth/server
/// rejection means the encoder is not confirmed gone; session-unknown statuses mean there is no live
/// job left to stop, so the caller can drop persisted retry state.
public enum MediaBrowserActiveEncodingStopPolicy {
    public static func isConfirmedStopped(httpStatus: Int?) -> Bool {
        guard let httpStatus else { return false }
        return (200..<300).contains(httpStatus) || httpStatus == 400 || httpStatus == 404 || httpStatus == 410
    }
}
