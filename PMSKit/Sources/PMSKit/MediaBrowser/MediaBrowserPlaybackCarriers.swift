import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Backend-neutral MediaBrowser playback method used by the app's shared remote-player path.
public enum MediaBrowserPlayMethod: String, Sendable, Equatable {
    case directPlay
    case directStream
    case transcode
}

/// Backend-neutral source metadata for the app's shared Jellyfin/Emby remote-player path.
public struct MediaBrowserPlaybackSourceMetadata: Sendable, Equatable {
    public static let empty = MediaBrowserPlaybackSourceMetadata()

    public let container: String?
    public let width: Int?
    public let height: Int?
    /// Kbps, matching Plex `Media.bitrate` units used by the diagnostics UI.
    public let bitrate: Int?
    public let videoCodec: String?
    public let audioCodec: String?
    /// Source HDR facts from the selected video stream, when the server exposed any. (#195)
    public let hdr: VideoHDRMetadata?
    /// Audio codec profile of the selected audio stream, e.g. "Dolby TrueHD + Dolby Atmos". (#195)
    public let audioProfile: String?

    public init(container: String? = nil,
                width: Int? = nil,
                height: Int? = nil,
                bitrate: Int? = nil,
                videoCodec: String? = nil,
                audioCodec: String? = nil,
                hdr: VideoHDRMetadata? = nil,
                audioProfile: String? = nil) {
        self.container = container
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.hdr = hdr
        self.audioProfile = audioProfile
    }
}

/// Backend-neutral playback open result produced directly by Jellyfin and Emby resolution.
public struct MediaBrowserPlaybackOpenResult: Sendable, Equatable {
    public let url: URL
    public let playSessionId: String
    public let mediaSourceId: String
    public let playMethod: MediaBrowserPlayMethod
    public let requiredHTTPHeaders: [String: String]
    public let sourceMetadata: MediaBrowserPlaybackSourceMetadata
    public let usesServerEncoding: Bool
    /// Backend reason enum names from PlaybackInfo. These remain internal carrier facts; player
    /// UI and exported diagnostics consume only `PlaybackExplanation`'s normalized buckets.
    public let transcodeReasons: [String]

    public init(url: URL,
                playSessionId: String,
                mediaSourceId: String,
                playMethod: MediaBrowserPlayMethod,
                requiredHTTPHeaders: [String: String] = [:],
                sourceMetadata: MediaBrowserPlaybackSourceMetadata = .empty,
                usesServerEncoding: Bool = false,
                transcodeReasons: [String] = []) {
        self.url = url
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.playMethod = playMethod
        self.requiredHTTPHeaders = requiredHTTPHeaders
        self.sourceMetadata = sourceMetadata
        self.usesServerEncoding = usesServerEncoding
        self.transcodeReasons = transcodeReasons
    }
}
