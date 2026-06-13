import Foundation

/// Safety net: PMS normally emits relative URIs (which resolve back to the loopback base on
/// their own), but if a playlist ever contains an *absolute* PMS URL, rewrite it to the
/// loopback base so the follow-up request comes back through the proxy. Only touches playlist
/// bodies — never segment/media bytes, which could coincidentally contain the upstream string.
struct PlaylistRewriter {
    let upstreamBase: URL
    let loopbackBase: URL

    func rewrite(_ body: Data, contentType: String?) -> Data {
        guard isPlaylist(contentType: contentType, body: body) else { return body }
        guard let text = String(data: body, encoding: .utf8) else { return body }
        var up = upstreamBase.absoluteString
        while up.hasSuffix("/") { up.removeLast() }
        var loop = loopbackBase.absoluteString
        while loop.hasSuffix("/") { loop.removeLast() }
        guard text.contains(up) else { return body }
        return Data(text.replacingOccurrences(of: up, with: loop).utf8)
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
