import Foundation
import PMSKit

/// Immutable Plex authority needed for one playback controller lifetime.
struct PlexPlaybackSession {
    let server: URL
    let token: String
    let machineIdentifier: String?
    let initialResumeMsOverride: Int?

    init(server: URL,
         token: String,
         machineIdentifier: String? = nil,
         initialResumeMsOverride: Int? = nil) {
        self.server = server
        self.token = token
        self.machineIdentifier = machineIdentifier
        self.initialResumeMsOverride = initialResumeMsOverride
    }
}

/// Immutable local-file authority and side assets for one offline playback controller.
struct OfflinePlaybackSession {
    let fileURL: URL
    let textSubtitles: [OfflineTextSubtitleTrack]
    let chapterImageURLs: [Int: URL]
    let onPlaybackProgress: ((Int, Int?) -> Void)?

    init(fileURL: URL,
         textSubtitles: [OfflineTextSubtitleTrack] = [],
         chapterImageURLs: [Int: URL] = [:],
         onPlaybackProgress: ((Int, Int?) -> Void)? = nil) {
        self.fileURL = fileURL
        self.textSubtitles = textSubtitles
        self.chapterImageURLs = chapterImageURLs
        self.onPlaybackProgress = onPlaybackProgress
    }

    var subtitleBaseURL: URL {
        fileURL.deletingLastPathComponent()
    }
}

/// Result of reopening an already-negotiated Jellyfin/Emby stream.
struct RemoteStreamOpenResult {
    let url: URL
    let headers: [String: String]
    let playSessionId: String?
    let mediaSourceId: String?
    let sourceMetadata: MediaBrowserPlaybackSourceMetadata?
    let playMethod: MediaBrowserPlayMethod?
    let transcodeReasons: [String]?
    let onStop: (() -> Void)?

    init(url: URL,
         headers: [String: String],
         playSessionId: String? = nil,
         mediaSourceId: String? = nil,
         sourceMetadata: MediaBrowserPlaybackSourceMetadata? = nil,
         playMethod: MediaBrowserPlayMethod? = nil,
         transcodeReasons: [String]? = nil,
         onStop: (() -> Void)? = nil) {
        self.url = url
        self.headers = headers
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.sourceMetadata = sourceMetadata
        self.playMethod = playMethod
        self.transcodeReasons = transcodeReasons
        self.onStop = onStop
    }
}

struct RemoteStreamReopenRequest: Sendable {
    let offsetMs: Int
    let bitrateKbps: Int
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?

    init(offsetMs: Int,
         bitrateKbps: Int,
         audioStreamIndex: Int? = nil,
         subtitleStreamIndex: Int? = nil) {
        self.offsetMs = offsetMs
        self.bitrateKbps = bitrateKbps
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
    }
}

typealias RemoteStreamReopener = (RemoteStreamReopenRequest) async throws -> RemoteStreamOpenResult

/// Cohesive current state for one negotiated Jellyfin/Emby playback session.
///
/// Reopens replace the mutable stream/progress facts in place. Keeping them under the typed
/// `.mediaBrowser` source prevents a controller from representing a remote URL without the
/// matching reopener, progress authority, and cleanup callback.
@MainActor
final class MediaBrowserPlaybackSession {
    let initialStreamURL: URL
    let backend: MediaBackendID
    let backendLabel: String
    let reopener: RemoteStreamReopener

    var httpHeaders: [String: String]
    var sourceMetadata: MediaBrowserPlaybackSourceMetadata?
    var playMethod: MediaBrowserPlayMethod?
    var transcodeReasons: [String]
    var playSessionID: String?
    var progressSession: MediaBrowserPlaybackProgressSession?
    var onStop: (() -> Void)?
    var didStop = false

    init(streamURL: URL,
         backend: MediaBackendID? = nil,
         backendLabel: String,
         httpHeaders: [String: String],
         playSessionID: String,
         sourceMetadata: MediaBrowserPlaybackSourceMetadata,
         playMethod: MediaBrowserPlayMethod,
         transcodeReasons: [String],
         progressSession: MediaBrowserPlaybackProgressSession?,
         onStop: @escaping () -> Void,
         reopener: @escaping RemoteStreamReopener) {
        self.initialStreamURL = streamURL
        self.backend = backend
            ?? MediaBackendID.allCases.first(where: {
                $0.displayName.caseInsensitiveCompare(backendLabel) == .orderedSame
            })
            ?? .jellyfin
        self.backendLabel = backendLabel
        self.httpHeaders = httpHeaders
        self.playSessionID = playSessionID
        self.sourceMetadata = sourceMetadata
        self.playMethod = playMethod
        self.transcodeReasons = transcodeReasons
        self.progressSession = progressSession
        self.onStop = onStop
        self.reopener = reopener
    }
}

/// The only three valid playback authorities. Associated carriers make illegal combinations such
/// as an offline file with a remote reopener or a MediaBrowser URL without cleanup unrepresentable.
enum PlaybackSessionSource {
    enum Kind: Equatable, Sendable {
        case plex
        case mediaBrowser
        case offline
    }

    case plex(PlexPlaybackSession)
    case mediaBrowser(MediaBrowserPlaybackSession)
    case offline(OfflinePlaybackSession)

    var kind: Kind {
        switch self {
        case .plex: .plex
        case .mediaBrowser: .mediaBrowser
        case .offline: .offline
        }
    }

    var pathMode: String {
        switch self {
        case .plex: "plex_stream"
        case .mediaBrowser: "remote_stream"
        case .offline: "local_file"
        }
    }

    var supportsStreamReopen: Bool {
        switch self {
        case .plex, .mediaBrowser: true
        case .offline: false
        }
    }
}
