import Foundation
import PMSKit

/// Value-only MediaBrowser progress context captured at the app boundary.
///
/// `PlaybackController` updates the mutable fields when a Jellyfin/Emby stream is
/// reopened, while `TimelineReporter` turns this into Playing/Progress/Stopped
/// requests. This intentionally stays independent of the local HLS proxy path.
struct MediaBrowserPlaybackProgressSession: Equatable {
    enum Backend: String, Equatable {
        case jellyfin
        case emby
    }

    var backend: Backend
    var server: URL
    var token: String
    var userID: String
    var identity: ClientIdentity
    var itemID: String
    var mediaSourceID: String
    var playSessionID: String
    var playMethod: MediaBrowserPlayMethod

    var sessionKey: String {
        "\(backend.rawValue)|\(itemID)|\(mediaSourceID)|\(playSessionID)"
    }

    func request(for event: MediaBrowserPlaybackProgressEvent,
                 positionMs: Int,
                 isPaused: Bool) throws -> URLRequest {
        let ticks = MediaBrowserPlaybackProgressPolicy.positionTicks(milliseconds: positionMs)
        switch backend {
        case .jellyfin:
            let method = jellyfinPlayMethod
            switch event {
            case .playing:
                return try JellyfinPlayback.playingRequest(server: server,
                                                           token: token,
                                                           identity: identity.jellyfin,
                                                           userId: userID,
                                                           itemId: itemID,
                                                           mediaSourceId: mediaSourceID,
                                                           playSessionId: playSessionID,
                                                           playMethod: method,
                                                           positionTicks: ticks)
            case .progress:
                return try JellyfinPlayback.progressRequest(server: server,
                                                            token: token,
                                                            identity: identity.jellyfin,
                                                            userId: userID,
                                                            itemId: itemID,
                                                            mediaSourceId: mediaSourceID,
                                                            playSessionId: playSessionID,
                                                            playMethod: method,
                                                            positionTicks: ticks,
                                                            isPaused: isPaused)
            case .stopped:
                return try JellyfinPlayback.stoppedRequest(server: server,
                                                           token: token,
                                                           identity: identity.jellyfin,
                                                           userId: userID,
                                                           itemId: itemID,
                                                           mediaSourceId: mediaSourceID,
                                                           playSessionId: playSessionID,
                                                           playMethod: method,
                                                           positionTicks: ticks)
            }
        case .emby:
            let method = embyPlayMethod
            switch event {
            case .playing:
                return try EmbyPlayback.playingRequest(server: server,
                                                       token: token,
                                                       identity: identity.emby,
                                                       userId: userID,
                                                       itemId: itemID,
                                                       mediaSourceId: mediaSourceID,
                                                       playSessionId: playSessionID,
                                                       playMethod: method,
                                                       positionTicks: ticks)
            case .progress:
                return try EmbyPlayback.progressRequest(server: server,
                                                        token: token,
                                                        identity: identity.emby,
                                                        userId: userID,
                                                        itemId: itemID,
                                                        mediaSourceId: mediaSourceID,
                                                        playSessionId: playSessionID,
                                                        playMethod: method,
                                                        positionTicks: ticks,
                                                        isPaused: isPaused)
            case .stopped:
                return try EmbyPlayback.stoppedRequest(server: server,
                                                       token: token,
                                                       identity: identity.emby,
                                                       userId: userID,
                                                       itemId: itemID,
                                                       mediaSourceId: mediaSourceID,
                                                       playSessionId: playSessionID,
                                                       playMethod: method,
                                                       positionTicks: ticks)
            }
        }
    }

    private var jellyfinPlayMethod: JellyfinPlayMethod {
        switch playMethod {
        case .directPlay: return .directPlay
        case .directStream: return .directStream
        case .transcode: return .transcode
        }
    }

    private var embyPlayMethod: EmbyPlayMethod {
        switch playMethod {
        case .directPlay: return .directPlay
        case .directStream: return .directStream
        case .transcode: return .transcode
        }
    }
}
