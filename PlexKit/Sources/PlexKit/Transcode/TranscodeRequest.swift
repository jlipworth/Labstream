import Foundation

/// Builds the two PMS "universal transcode" URLs from one shared parameter set:
///   - `decisionURL()`     → `/video/:/transcode/universal/decision`  (+ `hasMDE=1`)
///   - `startM3U8URL()`    → `/video/:/transcode/universal/start.m3u8`
///
/// Port of `python-plexapi.getStreamURL()` param shapes (research/09).
///
/// IMPORTANT: `partIndex` is its OWN index into a media item's parts. python-plexapi
/// has a long-standing bug where it passes `partIndex=mediaIndex` (research/09); we do
/// NOT replicate that — `mediaIndex` and `partIndex` are independent here.
public struct TranscodeRequest: Sendable, Equatable {
    /// Server base URL, e.g. `https://192.168.1.10:32400`.
    public let server: URL
    /// Plex auth token, sent as the `X-Plex-Token` QUERY param (not a header) on streaming URLs.
    public let token: String
    public let identity: ClientIdentity
    /// The metadata key, e.g. `/library/metadata/101`. Sent as the `path` param.
    public let metadataKey: String
    /// Hard cap on transcoded video bitrate, in kbps.
    public let maxVideoBitrateKbps: Int
    /// Per-playback transcode session identifier.
    public let sessionID: String
    /// Index into the item's `Media` array.
    public let mediaIndex: Int
    /// Index into the chosen `Media`'s `Part` array. INDEPENDENT of `mediaIndex`.
    public let partIndex: Int
    /// When non-nil, requests subtitle burn-in for the given stream id (`subtitleStreamID`)
    /// with `subtitleSize`. When nil, subtitles are left as `auto`.
    public let burnSubtitleStreamID: Int?

    public init(server: URL,
                token: String,
                identity: ClientIdentity,
                metadataKey: String,
                maxVideoBitrateKbps: Int,
                sessionID: String,
                mediaIndex: Int,
                partIndex: Int,
                burnSubtitleStreamID: Int? = nil) {
        self.server = server
        self.token = token
        self.identity = identity
        self.metadataKey = metadataKey
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.sessionID = sessionID
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
        self.burnSubtitleStreamID = burnSubtitleStreamID
    }

    /// The device profile advertised to PMS for this request.
    public var deviceProfile: DeviceProfile {
        DeviceProfile.visionOS(maxVideoBitrateKbps: maxVideoBitrateKbps)
    }

    /// The shared parameter set used by both URLs.
    public func sharedQueryItems() -> [URLQueryItem] {
        var items: [URLQueryItem] = [
            .init(name: "path", value: metadataKey),
            .init(name: "protocol", value: "hls"),
            .init(name: "maxVideoBitrate", value: String(maxVideoBitrateKbps)),
            .init(name: "videoQuality", value: "100"),
            .init(name: "directPlay", value: "0"),
            .init(name: "directStream", value: "1"),
            .init(name: "audioBoost", value: "100"),
            .init(name: "mediaIndex", value: String(mediaIndex)),
            // partIndex is its own index — do NOT tie it to mediaIndex.
            .init(name: "partIndex", value: String(partIndex)),
            .init(name: "session", value: sessionID),
            .init(name: "X-Plex-Client-Profile-Name", value: "visionOS"),
            .init(name: "X-Plex-Client-Profile-Extra", value: deviceProfile.clientProfileExtra),
        ]

        // Subtitles: either burn-in a specific stream, or let PMS auto-select.
        if let sid = burnSubtitleStreamID {
            items.append(.init(name: "subtitles", value: "burn"))
            items.append(.init(name: "subtitleStreamID", value: String(sid)))
            items.append(.init(name: "subtitleSize", value: "100"))
        } else {
            items.append(.init(name: "subtitles", value: "auto"))
        }

        // Standard X-Plex-* identity params (sent on the URL for streaming endpoints),
        // including the token as a query param.
        for (name, value) in PlexHeaders.standard(identity: identity, token: token) {
            guard name.hasPrefix("X-Plex-") else { continue }
            // Profile name/extra already added explicitly above.
            if name == "X-Plex-Client-Profile-Name" || name == "X-Plex-Client-Profile-Extra" {
                continue
            }
            items.append(.init(name: name, value: value))
        }

        return items
    }

    /// `/video/:/transcode/universal/decision` + the shared params + `hasMDE=1`.
    public func decisionURL() -> URL {
        var items = sharedQueryItems()
        items.append(.init(name: "hasMDE", value: "1"))
        return buildURL(path: "/video/:/transcode/universal/decision", queryItems: items)
    }

    /// `/video/:/transcode/universal/start.m3u8` + the shared params.
    public func startM3U8URL() -> URL {
        buildURL(path: "/video/:/transcode/universal/start.m3u8", queryItems: sharedQueryItems())
    }

    private func buildURL(path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.path = path
        components.queryItems = queryItems
        return components.url!
    }
}
