import Foundation

/// What `MediaSessionProxy.open`/`seek` hand back to the renderer. No AVFoundation types
/// cross this boundary — the player just consumes `localURL`.
public struct MediaSessionHandle: Sendable, Equatable {
    /// The loopback URL to hand to `AVURLAsset`. e.g. `http://127.0.0.1:51234/video/:/...`.
    public let localURL: URL
    /// Identifies this logical stream. Bumps on each `open`; `stop(generation:)` is a no-op
    /// for a stale generation so a late teardown can't kill a newer session.
    public let generation: Int

    public init(localURL: URL, generation: Int) {
        self.localURL = localURL
        self.generation = generation
    }
}

/// Observable session state for UI/diagnostics/tests. No AVFoundation leakage.
public struct MediaSessionStatus: Sendable, Equatable {
    public let generation: Int
    public let isOpen: Bool
    /// How many times the upstream socket has been rotated this session (#33 recovery count).
    public let rotateCount: Int

    public init(generation: Int, isOpen: Bool, rotateCount: Int) {
        self.generation = generation
        self.isOpen = isOpen
        self.rotateCount = rotateCount
    }
}

/// The Plex-aware input to `MediaSessionProxy.open` (#33 Stage 2). The proxy builds the
/// `TranscodeRequest` and runs the decision/probe itself from these fields — only the
/// control-plane TRANSPORT is injected (see `MediaSessionProxy.init`), never the app's
/// `PlexClient` (which is app-layer and must not cross into PMSKit).
public struct MediaSessionRequest: Sendable, Equatable {
    public let server: URL
    public let token: String
    public let identity: ClientIdentity
    public let metadataKey: String
    public let maxVideoBitrateKbps: Int
    public let sessionID: String
    public let mediaIndex: Int
    public let partIndex: Int
    /// Subtitle stream to burn in, or nil to leave PMS on `auto` (mirrors the player's
    /// current streaming request, which passes nil).
    public let burnSubtitleStreamID: Int?
    /// When true, the proxy probes the MDE with `directPlay=1` first and commits to the
    /// direct-play start URL when PMS confirms it will copy the video (#7). Off → today's
    /// transcode path, byte-identical.
    public let directStreamEnabled: Bool

    public init(server: URL, token: String, identity: ClientIdentity, metadataKey: String,
                maxVideoBitrateKbps: Int, sessionID: String, mediaIndex: Int, partIndex: Int,
                burnSubtitleStreamID: Int?, directStreamEnabled: Bool) {
        self.server = server
        self.token = token
        self.identity = identity
        self.metadataKey = metadataKey
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.sessionID = sessionID
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
        self.burnSubtitleStreamID = burnSubtitleStreamID
        self.directStreamEnabled = directStreamEnabled
    }
}

/// Errors surfaced across the media-session boundary (#33 Stage 2).
public enum MediaSessionError: Error, Sendable, Equatable {
    /// `seek`/`status` before a successful `open`.
    case notOpen
    /// The re-prime burst budget was exhausted — abusive scrubbing the stream can't sustain.
    /// The caller (PlaybackController) maps this to the failure overlay. `recentCount` is the
    /// number of restarts in the rolling window (for logging).
    case budgetEscalated(recentCount: Int)
    /// The loopback origin could not be stood up; the caller should load `directURL` directly
    /// (the Stage-1 fallback — playback must never depend on the proxy being up).
    case loopbackUnavailable(directURL: URL)
}
