import Foundation

/// Maps a loopback request-target back onto the PMS origin. Because PMS emits *relative*
/// playlist/segment URIs and `AVURLAsset` resolves them against the loopback base, every
/// request-target AVKit sends is already a valid PMS path+query — so mapping is a pure
/// origin swap (scheme/host/port), preserving the target's existing percent-encoding.
struct UpstreamURLMapper {
    /// PMS origin: scheme + host + port only (no path/query). Derive with
    /// `MediaSessionProxy` from the resolved HLS URL passed to `standUpLoopback`.
    let upstreamBase: URL

    func upstreamURL(forTarget target: String) -> URL? {
        guard target.hasPrefix("/") else { return nil }
        // Build by string concatenation (not URLComponents) to preserve the exact
        // percent-encoding AVKit sent — re-encoding can corrupt the X-Plex token/query.
        var base = upstreamBase.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + target)
    }
}
