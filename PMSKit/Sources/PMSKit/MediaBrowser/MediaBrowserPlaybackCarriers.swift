import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Backend-neutral MediaBrowser playback method used by the app's shared remote-player path.
public enum MediaBrowserPlayMethod: String, Sendable, Equatable {
    case directPlay
    case directStream
    case transcode

    public init(_ method: JellyfinPlayMethod) {
        switch method {
        case .directPlay: self = .directPlay
        case .directStream: self = .directStream
        case .transcode: self = .transcode
        }
    }

    public init(_ method: EmbyPlayMethod) {
        switch method {
        case .directPlay: self = .directPlay
        case .directStream: self = .directStream
        case .transcode: self = .transcode
        }
    }
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

    public init(_ source: JellyfinPlaybackSourceMetadata) {
        self.init(container: source.container,
                  width: source.width,
                  height: source.height,
                  bitrate: source.bitrate,
                  videoCodec: source.videoCodec,
                  audioCodec: source.audioCodec,
                  hdr: source.hdr,
                  audioProfile: source.audioProfile)
    }

    public init(_ source: EmbyPlaybackSourceMetadata) {
        self.init(container: source.container,
                  width: source.width,
                  height: source.height,
                  bitrate: source.bitrate,
                  videoCodec: source.videoCodec,
                  audioCodec: source.audioCodec,
                  hdr: source.hdr,
                  audioProfile: source.audioProfile)
    }
}

/// Backend-neutral playback open result for the app layer. Backend services still construct
/// their native PMSKit result types; the app explicitly converts those results at its boundary.
public struct MediaBrowserPlaybackOpenResult: Sendable, Equatable {
    public let url: URL
    public let playSessionId: String
    public let mediaSourceId: String
    public let playMethod: MediaBrowserPlayMethod
    public let requiredHTTPHeaders: [String: String]
    public let sourceMetadata: MediaBrowserPlaybackSourceMetadata
    public let usesServerEncoding: Bool

    public init(url: URL,
                playSessionId: String,
                mediaSourceId: String,
                playMethod: MediaBrowserPlayMethod,
                requiredHTTPHeaders: [String: String] = [:],
                sourceMetadata: MediaBrowserPlaybackSourceMetadata = .empty,
                usesServerEncoding: Bool = false) {
        self.url = url
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.playMethod = playMethod
        self.requiredHTTPHeaders = requiredHTTPHeaders
        self.sourceMetadata = sourceMetadata
        self.usesServerEncoding = usesServerEncoding
    }

    public init(_ result: JellyfinPlaybackOpenResult) {
        self.init(url: result.url,
                  playSessionId: result.playSessionId,
                  mediaSourceId: result.mediaSourceId,
                  playMethod: MediaBrowserPlayMethod(result.playMethod),
                  requiredHTTPHeaders: result.requiredHTTPHeaders,
                  sourceMetadata: MediaBrowserPlaybackSourceMetadata(result.sourceMetadata),
                  usesServerEncoding: result.playMethod == .transcode)
    }

    public init(_ result: EmbyPlaybackOpenResult) {
        self.init(url: result.url,
                  playSessionId: result.playSessionId,
                  mediaSourceId: result.mediaSourceId,
                  playMethod: MediaBrowserPlayMethod(result.playMethod),
                  requiredHTTPHeaders: result.requiredHTTPHeaders,
                  sourceMetadata: MediaBrowserPlaybackSourceMetadata(result.sourceMetadata),
                  usesServerEncoding: result.usesServerEncoding)
    }
}
