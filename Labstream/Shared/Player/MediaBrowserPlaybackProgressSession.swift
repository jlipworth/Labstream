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
        let requestEvent: MediaBrowserPlaybackProgressRequestEvent = switch event {
        case .playing: .playing
        case .progress: isPaused ? .paused : .progress
        case .stopped: .stopped
        }
        guard let url = MediaBrowserURL.join(server: server,
                                             pathOrURLString: requestEvent.endpoint.rawValue) else {
            throw URLError(.badURL)
        }
        let authDialect: MediaBrowserPlaybackProgressAuthDialect = switch backend {
        case .jellyfin: .jellyfin(identity.jellyfin)
        case .emby: .emby(identity.emby)
        }
        return try MediaBrowserPlaybackProgressRequestPlan(
            url: url,
            authDialect: authDialect,
            event: requestEvent,
            payload: MediaBrowserPlaybackProgressPayload(
                userId: userID,
                itemId: itemID,
                mediaSourceId: mediaSourceID,
                playSessionId: playSessionID,
                playMethod: playMethod,
                positionTicks: ticks
            )
        ).request(token: token)
    }
}
