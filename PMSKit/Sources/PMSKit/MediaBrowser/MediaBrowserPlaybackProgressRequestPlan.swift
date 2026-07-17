import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The server endpoint used by a MediaBrowser playback progress event.
public enum MediaBrowserPlaybackProgressEndpoint: String, Sendable, Equatable {
    case playing = "/Sessions/Playing"
    case progress = "/Sessions/Playing/Progress"
    case stopped = "/Sessions/Playing/Stopped"
}

/// The four semantic progress events emitted by the shared Jellyfin/Emby player path.
///
/// `progress` and `paused` intentionally share an endpoint. They remain distinct values so
/// callers cannot accidentally report a paused heartbeat with `IsPaused=false`.
public enum MediaBrowserPlaybackProgressRequestEvent: Sendable, Equatable {
    case playing
    case progress
    case paused
    case stopped

    public var endpoint: MediaBrowserPlaybackProgressEndpoint {
        switch self {
        case .playing: .playing
        case .progress, .paused: .progress
        case .stopped: .stopped
        }
    }

    public var isPaused: Bool {
        self == .paused
    }
}

/// Backend-neutral facts carried by every MediaBrowser progress request.
public struct MediaBrowserPlaybackProgressPayload: Sendable, Equatable {
    public let userId: String
    public let itemId: String
    public let mediaSourceId: String
    public let playSessionId: String
    public let playMethod: MediaBrowserPlayMethod
    public let positionTicks: Int

    public init(userId: String,
                itemId: String,
                mediaSourceId: String,
                playSessionId: String,
                playMethod: MediaBrowserPlayMethod,
                positionTicks: Int) {
        self.userId = userId
        self.itemId = itemId
        self.mediaSourceId = mediaSourceId
        self.playSessionId = playSessionId
        self.playMethod = playMethod
        self.positionTicks = positionTicks
    }
}

/// Authentication is the only header-level difference in the shared progress request.
/// Tokens are supplied only when materializing a request and are never retained by this value.
public enum MediaBrowserPlaybackProgressAuthDialect: Sendable, Equatable {
    case jellyfin(JellyfinClientIdentity)
    case emby(EmbyClientIdentity)
}

/// A value-only plan for constructing a Jellyfin or Emby playback progress request.
///
/// The caller resolves the backend-specific URL first, preserving its existing error type and
/// base-path join semantics. The plan then owns the byte-compatible shared method, headers, and
/// sorted JSON body. It deliberately does not store the access token, keeping diagnostics of the
/// plan itself credential-free.
public struct MediaBrowserPlaybackProgressRequestPlan: Sendable, Equatable, CustomStringConvertible {
    public let url: URL
    public let authDialect: MediaBrowserPlaybackProgressAuthDialect
    public let event: MediaBrowserPlaybackProgressRequestEvent
    public let payload: MediaBrowserPlaybackProgressPayload

    public init(url: URL,
                authDialect: MediaBrowserPlaybackProgressAuthDialect,
                event: MediaBrowserPlaybackProgressRequestEvent,
                payload: MediaBrowserPlaybackProgressPayload) {
        self.url = url
        self.authDialect = authDialect
        self.event = event
        self.payload = payload
    }

    /// A deliberately sparse, privacy-safe diagnostic description. In particular, the server
    /// URL, item/session identifiers, and token are never rendered.
    public var description: String {
        "MediaBrowserPlaybackProgressRequestPlan(event: \(event), auth: \(authName))"
    }

    public func request(token: String) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        switch authDialect {
        case .jellyfin(let identity):
            request.setValue(JellyfinAuth.authorizationHeader(identity: identity, token: token),
                             forHTTPHeaderField: "Authorization")
        case .emby(let identity):
            request.setValue(EmbyAuth.authorizationHeader(identity: identity,
                                                           userId: payload.userId,
                                                           token: token),
                             forHTTPHeaderField: "Authorization")
            if !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        request.httpBody = try encoder.encode(WirePayload(payload: payload,
                                                          event: event,
                                                          includesUserId: includesUserIdInBody))
        return request
    }

    private var includesUserIdInBody: Bool {
        if case .jellyfin = authDialect { true } else { false }
    }

    private var authName: String {
        switch authDialect {
        case .jellyfin: "jellyfin"
        case .emby: "emby"
        }
    }

    private struct WirePayload: Encodable {
        let userId: String?
        let itemId: String
        let mediaSourceId: String
        let playSessionId: String
        let positionTicks: Int
        let isPaused: Bool
        let playMethod: String

        init(payload: MediaBrowserPlaybackProgressPayload,
             event: MediaBrowserPlaybackProgressRequestEvent,
             includesUserId: Bool) {
            userId = includesUserId ? payload.userId : nil
            itemId = payload.itemId
            mediaSourceId = payload.mediaSourceId
            playSessionId = payload.playSessionId
            positionTicks = payload.positionTicks
            isPaused = event.isPaused
            switch payload.playMethod {
            case .directPlay: playMethod = "DirectPlay"
            case .directStream: playMethod = "DirectStream"
            case .transcode: playMethod = "Transcode"
            }
        }

        enum CodingKeys: String, CodingKey {
            case userId = "UserId"
            case itemId = "ItemId"
            case mediaSourceId = "MediaSourceId"
            case playSessionId = "PlaySessionId"
            case positionTicks = "PositionTicks"
            case isPaused = "IsPaused"
            case playMethod = "PlayMethod"
        }
    }
}
