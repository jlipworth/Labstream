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
    /// Server base URL, e.g. `https://192.0.2.10:32400`.
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
    /// Resume position in **seconds**. When non-nil/>0, PMS primes the transcoder AT
    /// this point and emits `#EXT-X-START:TIME-OFFSET` in the media playlist, so the
    /// player begins there with the first segment produced quickly — instead of PMS
    /// transcoding from 0 and the client precise-seeking into an unprimed position
    /// (which times out the deep segment and stalls the load). This is how official
    /// Plex clients resume. Streaming-only; the download URL strips it.
    public let startOffsetSeconds: Int?

    public init(server: URL,
                token: String,
                identity: ClientIdentity,
                metadataKey: String,
                maxVideoBitrateKbps: Int,
                sessionID: String,
                mediaIndex: Int,
                partIndex: Int,
                burnSubtitleStreamID: Int? = nil,
                startOffsetSeconds: Int? = nil) {
        self.server = server
        self.token = token
        self.identity = identity
        self.metadataKey = metadataKey
        self.maxVideoBitrateKbps = maxVideoBitrateKbps
        self.sessionID = sessionID
        self.mediaIndex = mediaIndex
        self.partIndex = partIndex
        self.burnSubtitleStreamID = burnSubtitleStreamID
        self.startOffsetSeconds = startOffsetSeconds
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
            // PMS resolves this name to a built-in profile file (`Profiles/<Name>.xml`).
            // There is NO "visionOS" profile on the server, and an unknown name makes
            // the universal transcoder return a bare HTTP 400 (verified against live
            // PMS). "Safari" is the closest built-in match: AVFoundation HLS with
            // HEVC/fMP4 support, which is exactly what our AVPlayer can play.
            .init(name: "X-Plex-Client-Profile-Name", value: "Safari"),
            .init(name: "X-Plex-Client-Profile-Extra", value: deviceProfile.clientProfileExtra),
        ]

        // Resume offset: tell PMS where to start the transcode session (seconds).
        if let off = startOffsetSeconds, off > 0 {
            items.append(.init(name: "offset", value: String(off)))
        }

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

    /// Decision-only probe URL (issue #7): same core params as `decisionURL()` but advertises
    /// direct-play capability (`directPlay=1`) and the direct-play probe profile. Hitting this
    /// against /decision tells us whether the title would Direct Play / Direct Stream within the
    /// cap. It does NOT change what the player loads — only `start.m3u8` (directPlay=0) is played.
    ///
    /// Built additively from `sharedQueryItems()`: we swap `directPlay` 0→1 and replace the
    /// `X-Plex-Client-Profile-Extra` with the direct-play probe variant, then append `hasMDE=1`.
    /// Everything else (path/protocol/session/token/maxVideoBitrate/mediaIndex/partIndex/profile
    /// name `Safari`/subtitles/offset/identity) is identical to `decisionURL()`. Query-param
    /// order is irrelevant to PMS, so this stays consistent with the production decision request.
    public func directPlayProbeDecisionURL() -> URL {
        var items = directPlayQueryItems()
        // Decision endpoint: ask the Media Decision Engine for its verdict.
        items.append(.init(name: "hasMDE", value: "1"))
        return buildURL(path: "/video/:/transcode/universal/decision", queryItems: items)
    }

    /// The **direct-play start URL** (#7 Step 3): `start.m3u8` with the exact param set the
    /// direct-play decision probe used (`directPlay=1` + the direct-play-capable profile).
    /// Only ever loaded after `directPlayProbeDecisionURL()`'s response shows PMS will copy
    /// the video stream (`DecisionResponse.savesVideoEncode`) — decision and start MUST stay
    /// param-identical or PMS may decide one thing and serve another (research/15 risk #8),
    /// which the shared `directPlayQueryItems()` guarantees structurally. Delivery is still
    /// HLS via the universal transcoder, so subtitles/resume/timeline paths are unchanged —
    /// PMS just remuxes (codec copy) instead of re-encoding.
    public func directPlayStartM3U8URL() -> URL {
        buildURL(path: "/video/:/transcode/universal/start.m3u8", queryItems: directPlayQueryItems())
    }

    /// `sharedQueryItems()` with the two direct-play deltas applied: `directPlay` 0→1 and the
    /// `X-Plex-Client-Profile-Extra` swapped for the direct-play-capable profile. Everything
    /// else (path/protocol/session/token/cap/indices/profile name `Safari`/subtitles/offset/
    /// identity) is identical to the production transcode params.
    private func directPlayQueryItems() -> [URLQueryItem] {
        var items = sharedQueryItems()
        // Allow direct play (production decision/start keep directPlay=0).
        items.removeAll { $0.name == "directPlay" }
        items.append(.init(name: "directPlay", value: "1"))
        // Advertise the direct-play-capable profile only on this path.
        items.removeAll { $0.name == "X-Plex-Client-Profile-Extra" }
        let probeProfile = DeviceProfile.visionOSDirectPlayProbe(maxVideoBitrateKbps: maxVideoBitrateKbps)
        items.append(.init(name: "X-Plex-Client-Profile-Extra", value: probeProfile.clientProfileExtra))
        return items
    }

    /// A **single-file** capped-bitrate transcode URL for OFFLINE DOWNLOAD.
    ///
    /// Streaming playback uses `start.m3u8` (segmented HLS), which a background
    /// `URLSession.downloadTask` cannot fetch as one file — it would only retrieve
    /// the playlist text, not the media segments. For a download we instead ask the
    /// SAME universal transcoder for a single progressive **MP4** by overriding
    /// `protocol=http` (instead of `hls`) and adding `download=1`. PMS streams the
    /// transcoded body inline, so one `downloadTask` captures the whole file.
    ///
    /// This reuses the verified streaming contract (`X-Plex-Client-Profile-Name=Safari`,
    /// the `maxVideoBitrate` cap, identity params, token-as-query) — the only
    /// differences are the `protocol` value and the `download` flag. The chosen
    /// `maxVideoBitrateKbps` is honored exactly as it is for streaming, so the
    /// download quality matches what the player would produce at that cap.
    ///
    /// Server-dependence: the universal transcoder must allow `protocol=http`
    /// (progressive) output for the source codec; PMS falls back to a remux/transcode
    /// to a compatible MP4 in practice. If a given server/codec refuses progressive
    /// output this returns a 4xx, which the caller surfaces as a transfer failure.
    public func downloadURL() -> URL {
        var items = sharedQueryItems()
        // Override the streaming `protocol=hls` with progressive `http` so PMS emits
        // a single seekable MP4 body rather than an HLS playlist + segments.
        items.removeAll { $0.name == "protocol" }
        items.append(.init(name: "protocol", value: "http"))
        items.append(.init(name: "download", value: "1"))
        // A download always captures the whole file from the start, never a resume point.
        items.removeAll { $0.name == "offset" }
        // `offline=1` hints PMS this is a sync/download session (best-effort; ignored
        // by servers that don't recognize it).
        items.append(.init(name: "offline", value: "1"))
        return buildURL(path: "/video/:/transcode/universal/start", queryItems: items)
    }

    /// `/video/:/transcode/universal/stop` — gracefully end the server-side transcode
    /// session. HLS playback gives PMS no signal that the client left (segments just
    /// stop being requested), so without this every player close/rebuild orphans a
    /// live FFmpeg job until the server's inactivity reaper notices — orphans burn
    /// CPU and count against the concurrent-transcode limit. Official clients hit
    /// this endpoint on close; so do we. Static because teardown happens long after
    /// the full `TranscodeRequest` parameter set is gone — only the session matters.
    public static func stop(server: URL,
                            token: String,
                            identity: ClientIdentity,
                            sessionID: String) -> PlexRequest {
        let url = server.appendingPathComponent("/video/:/transcode/universal/stop")
        var items: [URLQueryItem] = [
            .init(name: "session", value: sessionID),
            .init(name: "X-Plex-Token", value: token),
        ]
        items.append(contentsOf: TimelineRequest.identityQueryItems(identity))
        return PlexRequest(url: url, method: "GET",
                           queryItems: items,
                           headers: PlexHeaders.standard(identity: identity, token: token))
    }

    private func buildURL(path: String, queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: server, resolvingAgainstBaseURL: false) else {
            preconditionFailure("TranscodeRequest: server URL is not decomposable: \(server)")
        }
        components.path = path
        components.queryItems = queryItems
        guard let url = components.url else {
            preconditionFailure("TranscodeRequest: could not rebuild URL for path \(path)")
        }
        return url
    }
}
