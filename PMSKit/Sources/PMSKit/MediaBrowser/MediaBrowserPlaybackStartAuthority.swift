/// Session-scoped authority for the Jellyfin/Emby `Sessions/Playing` handshake.
///
/// Building or enqueueing a request does not start the reporting session. The caller commits the
/// `.playing` event only after its request executor accepts the HTTP response, so a failed first
/// request is retried before progress heartbeats are emitted.
public struct MediaBrowserPlaybackStartAuthority: Sendable {
    private var sessionKey: String?
    public private(set) var hasAcceptedStart = false

    public init() {}

    public func isCurrentSession(_ candidateSessionKey: String) -> Bool {
        sessionKey == candidateSessionKey
    }

    public mutating func event(for state: TimelineRequest.State,
                               sessionKey nextSessionKey: String) -> MediaBrowserPlaybackProgressEvent {
        if sessionKey != nextSessionKey {
            sessionKey = nextSessionKey
            hasAcceptedStart = false
        }
        return MediaBrowserPlaybackProgressPolicy.event(for: state,
                                                        hasStartedSession: hasAcceptedStart)
    }

    public mutating func recordAccepted(event: MediaBrowserPlaybackProgressEvent,
                                        sessionKey acceptedSessionKey: String) {
        guard sessionKey == acceptedSessionKey, event == .playing else { return }
        hasAcceptedStart = true
    }
}
