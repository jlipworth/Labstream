import Foundation

/// Playback-state request builders: `/:/timeline` and `/:/scrobble` (+ `/:/unscrobble`).
///
/// HTTP method gotcha (research/13): the official PMS Redoc declares
/// `timeline` as **POST** and `scrobble`/`unscrobble` as **PUT**. However, every
/// known legacy client (and python-plexapi) drives these endpoints with **GET**,
/// which is the known-working path. We therefore default `method` to `"GET"` but
/// expose it as a knob so the app can flip to the official verbs during a
/// live-test pass without changing call sites.
public enum TimelineRequest {

    /// Player state reported to `/:/timeline`.
    public enum State: String, Sendable, Equatable {
        case playing
        case paused
        case stopped
        case buffering
    }

    /// `/:/timeline` — periodic playback heartbeat.
    ///
    /// GOTCHA (research/13): on the timeline endpoint `key` is the metadata
    /// **path** (e.g. `/library/metadata/101`), NOT the bare ratingKey number.
    /// `ratingKey` carries the numeric id separately. Contrast `scrobble`, where
    /// `key` IS the bare number.
    ///
    /// - Parameters:
    ///   - server: base server URL (scheme+host+port), e.g. `https://192.168.1.10:32400`.
    ///   - token: Plex auth token (sent both as a query param and a header).
    ///   - identity: client identity for the standard `X-Plex-*` headers.
    ///   - ratingKey: bare numeric rating key, e.g. `"101"`.
    ///   - key: metadata path, e.g. `/library/metadata/101`.
    ///   - state: current player state.
    ///   - timeMs: current playback offset in milliseconds.
    ///   - durationMs: total media duration in milliseconds.
    ///   - method: HTTP verb. Defaults to the legacy-working `"GET"`. Official: `"POST"`.
    public static func timeline(server: URL,
                                token: String,
                                identity: ClientIdentity,
                                ratingKey: String,
                                key: String,
                                state: State,
                                timeMs: Int,
                                durationMs: Int,
                                method: String = "GET") -> PlexRequest {
        let url = server.appendingPathComponent("/:/timeline")
        var items: [URLQueryItem] = [
            .init(name: "ratingKey", value: ratingKey),
            .init(name: "key", value: key),               // PATH on timeline
            .init(name: "state", value: state.rawValue),
            .init(name: "time", value: String(timeMs)),
            .init(name: "duration", value: String(durationMs)),
            .init(name: "X-Plex-Token", value: token),
        ]
        items.append(contentsOf: identityQueryItems(identity))
        return PlexRequest(url: url, method: method,
                           queryItems: items,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// `/:/scrobble` — mark an item watched.
    ///
    /// GOTCHA (research/13): on scrobble/unscrobble `key` is the bare numeric
    /// ratingKey (e.g. `"101"`), NOT a metadata path. `identifier` must be the
    /// library agent identifier.
    ///
    /// - Parameter method: HTTP verb. Defaults to legacy `"GET"`. Official: `"PUT"`.
    public static func scrobble(server: URL,
                                token: String,
                                identity: ClientIdentity,
                                ratingKey: String,
                                method: String = "GET") -> PlexRequest {
        marker(path: "/:/scrobble", server: server, token: token,
               identity: identity, ratingKey: ratingKey, method: method)
    }

    /// `/:/unscrobble` — mark an item unwatched.
    ///
    /// Same `key`-is-ratingKey-number semantics as `scrobble`.
    ///
    /// - Parameter method: HTTP verb. Defaults to legacy `"GET"`. Official: `"PUT"`.
    public static func unscrobble(server: URL,
                                  token: String,
                                  identity: ClientIdentity,
                                  ratingKey: String,
                                  method: String = "GET") -> PlexRequest {
        marker(path: "/:/unscrobble", server: server, token: token,
               identity: identity, ratingKey: ratingKey, method: method)
    }

    // MARK: - Helpers

    private static func marker(path: String,
                              server: URL,
                              token: String,
                              identity: ClientIdentity,
                              ratingKey: String,
                              method: String) -> PlexRequest {
        let url = server.appendingPathComponent(path)
        var items: [URLQueryItem] = [
            .init(name: "key", value: ratingKey),                              // NUMBER on scrobble
            .init(name: "identifier", value: "com.plexapp.plugins.library"),
            .init(name: "X-Plex-Token", value: token),
        ]
        items.append(contentsOf: identityQueryItems(identity))
        return PlexRequest(url: url, method: method,
                           queryItems: items,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    /// Standard `X-Plex-*` identity params carried on the query string.
    static func identityQueryItems(_ identity: ClientIdentity) -> [URLQueryItem] {
        [
            .init(name: "X-Plex-Client-Identifier", value: identity.clientIdentifier),
            .init(name: "X-Plex-Product", value: identity.product),
            .init(name: "X-Plex-Version", value: identity.version),
            .init(name: "X-Plex-Platform", value: "visionOS"),
            .init(name: "X-Plex-Device", value: "Apple Vision Pro"),
            .init(name: "X-Plex-Device-Name", value: identity.deviceName),
        ]
    }
}
