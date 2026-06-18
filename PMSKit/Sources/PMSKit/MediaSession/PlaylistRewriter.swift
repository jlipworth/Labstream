import Foundation

/// Safety net: PMS normally emits relative URIs (which resolve back to the loopback base on
/// their own), but if a playlist ever contains an *absolute* PMS URL, rewrite it to the
/// loopback base so the follow-up request comes back through the proxy. Only touches playlist
/// bodies — never segment/media bytes, which could coincidentally contain the upstream string.
struct PlaylistRewriter {
    let upstreamBase: URL
    let loopbackBase: URL
    var strippedQueryItemNames: Set<String> = []
    var injectedStartTimeOffsetSeconds: Double?

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
        guard rewritten != text else { return body }
        return Data(rewritten.utf8)
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
