import Foundation

/// GH #196 spike (b): the Dolby Vision signalling attributes injected into a master
/// playlist's `#EXT-X-STREAM-INF` lines so AVPlayer reads a copy-remuxed DV bitstream as DV
/// instead of plain HEVC. Experimental and debug-gated: claiming DV that the segments do not
/// actually carry produces exactly the broken rendering issue #196 exists to prevent, so this
/// only ever rides the experimental DV-signalling setting.
public struct MediaSessionDolbyVisionInjection: Sendable, Equatable {
    /// e.g. `dvh1.08.06/db1p` (P8, level 6, HDR10-compatible brand).
    public let supplementalCodecs: String
    /// HLS `VIDEO-RANGE` value: `PQ` or `HLG`.
    public let videoRange: String

    public init(supplementalCodecs: String, videoRange: String) {
        self.supplementalCodecs = supplementalCodecs
        self.videoRange = videoRange
    }

    /// Derive the injection from backend-reported DV facts. Deliberately narrow: only DV
    /// Profile 8 single-layer streams with a known compatible base layer (compat 1/6 → HDR10,
    /// compat 4 → HLG) have a valid SUPPLEMENTAL-CODECS form that Apple players support.
    /// P5 (no fallback), P7 (dual-layer, unsupported on Apple), and unknown compat return nil.
    public static func forDolbyVision(_ dv: VideoDolbyVisionInfo) -> MediaSessionDolbyVisionInjection? {
        guard dv.profile == 8, let level = dv.level else { return nil }
        let levelToken = String(format: "%02d", level)
        switch dv.blCompatibilityID {
        case 1, 6:
            return MediaSessionDolbyVisionInjection(supplementalCodecs: "dvh1.08.\(levelToken)/db1p",
                                                    videoRange: "PQ")
        case 4:
            return MediaSessionDolbyVisionInjection(supplementalCodecs: "dvh1.08.\(levelToken)/db4h",
                                                    videoRange: "HLG")
        default:
            return nil
        }
    }
}

/// Safety net: PMS normally emits relative URIs (which resolve back to the loopback base on
/// their own), but if a playlist ever contains an *absolute* PMS URL, rewrite it to the
/// loopback base so the follow-up request comes back through the proxy. Only touches playlist
/// bodies — never segment/media bytes, which could coincidentally contain the upstream string.
struct PlaylistRewriter {
    let upstreamBase: URL
    let loopbackBase: URL
    var strippedQueryItemNames: Set<String> = []
    var injectedStartTimeOffsetSeconds: Double?
    var dolbyVisionInjection: MediaSessionDolbyVisionInjection?

    func rewrite(_ body: Data, contentType: String?) -> Data {
        guard isPlaylist(contentType: contentType, body: body) else { return body }
        guard let text = String(data: body, encoding: .utf8) else { return body }
        var up = upstreamBase.absoluteString
        while up.hasSuffix("/") { up.removeLast() }
        var loop = loopbackBase.absoluteString
        while loop.hasSuffix("/") { loop.removeLast() }
        var rewritten = text
        if rewritten.contains(up) {
            rewritten = rewritten.replacingOccurrences(of: up, with: loop)
        }
        if !strippedQueryItemNames.isEmpty {
            rewritten = stripQueryItems(inPlaylist: rewritten)
        }
        if let injectedStartTimeOffsetSeconds {
            rewritten = injectStartTimeOffsetIfNeeded(inPlaylist: rewritten,
                                                      offsetSeconds: injectedStartTimeOffsetSeconds)
        }
        if let dolbyVisionInjection {
            rewritten = injectDolbyVisionAttributes(inPlaylist: rewritten,
                                                    injection: dolbyVisionInjection)
        }
        guard rewritten != text else { return body }
        return Data(rewritten.utf8)
    }

    /// Append `SUPPLEMENTAL-CODECS` and `VIDEO-RANGE` to master-playlist variant lines that
    /// lack them. Media playlists (no `#EXT-X-STREAM-INF`) pass through untouched.
    private func injectDolbyVisionAttributes(inPlaylist text: String,
                                             injection: MediaSessionDolbyVisionInjection) -> String {
        guard text.contains("#EXT-X-STREAM-INF:") else { return text }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var raw = String(line)
                guard raw.hasPrefix("#EXT-X-STREAM-INF:") else { return raw }
                if !raw.contains("SUPPLEMENTAL-CODECS") {
                    raw += ",SUPPLEMENTAL-CODECS=\"\(injection.supplementalCodecs)\""
                }
                if !raw.contains("VIDEO-RANGE") {
                    raw += ",VIDEO-RANGE=\(injection.videoRange)"
                }
                return raw
            }
            .joined(separator: "\n")
    }

    private func injectStartTimeOffsetIfNeeded(inPlaylist text: String,
                                               offsetSeconds: Double) -> String {
        guard text.hasPrefix("#EXTM3U"), !text.contains("#EXT-X-START:") else { return text }
        let start = String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=NO", offsetSeconds)
        guard let firstNewline = text.firstIndex(of: "\n") else {
            return text + "\n" + start + "\n"
        }
        var rewritten = text
        rewritten.insert(contentsOf: start + "\n", at: text.index(after: firstNewline))
        return rewritten
    }

    private func stripQueryItems(inPlaylist text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let raw = String(line)
                guard !raw.hasPrefix("#"), raw.contains("?") else { return raw }
                return stripQueryItems(fromURI: raw)
            }
            .joined(separator: "\n")
    }

    private func stripQueryItems(fromURI uri: String) -> String {
        guard var comps = URLComponents(string: uri),
              let items = comps.queryItems else { return uri }
        comps.queryItems = items.filter { item in
            !strippedQueryItemNames.contains(item.name.lowercased())
        }
        if comps.queryItems?.isEmpty == true {
            comps.queryItems = nil
        }
        return comps.string ?? uri
    }

    private func isPlaylist(contentType: String?, body: Data) -> Bool {
        if let ct = contentType?.lowercased(),
           ct.contains("mpegurl") || ct.contains("m3u") {
            return true
        }
        // Fallback to content sniffing: HLS playlists start with the #EXTM3U tag.
        return body.starts(with: Data("#EXTM3U".utf8))
    }
}
