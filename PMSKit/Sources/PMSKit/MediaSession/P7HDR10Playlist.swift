import Foundation

/// Admission for the narrow, unencrypted single-rendition fMP4 candidate. Multi-variant,
/// byte-range, discontinuous, and encrypted delivery are explicit unsupported gates, not
/// opportunities to guess which bytes carry the authoritative initialization.
enum P7HDR10Playlist {
    struct Media: Equatable, Sendable {
        let initialization: URL
        let segments: [URL]
    }
    enum Rejection: Error { case unsupported }

    static func parse(_ data: Data, at base: URL) throws -> Media {
        guard data.count <= 262_144, let text = String(data: data, encoding: .utf8),
              text.hasPrefix("#EXTM3U\n") || text.hasPrefix("#EXTM3U\r\n"),
              ["http", "https"].contains(base.scheme), base.user == nil, base.password == nil else {
            throw Rejection.unsupported
        }
        func resolve(_ value: String) throws -> URL {
            guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.contains("\\"), let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  url.scheme == base.scheme, url.host == base.host, url.port == base.port,
                  url.user == nil, url.password == nil, url.fragment == nil else { throw Rejection.unsupported }
            return url
        }
        var initialization: URL?
        var segments: [URL] = []
        var pendingDuration = false
        let allowedTags: Set<String> = ["#EXTM3U", "#EXT-X-VERSION", "#EXT-X-TARGETDURATION",
            "#EXT-X-MEDIA-SEQUENCE", "#EXT-X-PLAYLIST-TYPE", "#EXT-X-ENDLIST", "#EXT-X-INDEPENDENT-SEGMENTS"]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("#EXT-X-MAP:") {
                // Exactly one URI attribute; rejects BYTERANGE and ambiguous quoting.
                let prefix = "#EXT-X-MAP:URI=\""
                guard initialization == nil, segments.isEmpty, !pendingDuration,
                      line.hasPrefix(prefix), line.hasSuffix("\"") else { throw Rejection.unsupported }
                let uri = String(line.dropFirst(prefix.count).dropLast())
                guard !uri.contains("\"") else { throw Rejection.unsupported }
                initialization = try resolve(uri)
            } else if line.hasPrefix("#EXTINF:") {
                guard initialization != nil, !pendingDuration,
                      let token = line.dropFirst(8).split(separator: ",", omittingEmptySubsequences: false).first,
                      let duration = Double(token), duration.isFinite, duration > 0 else { throw Rejection.unsupported }
                pendingDuration = true
            } else if line.hasPrefix("#") {
                let tag = String(line.split(separator: ":", maxSplits: 1)[0])
                guard allowedTags.contains(tag), !pendingDuration else { throw Rejection.unsupported }
            } else {
                guard pendingDuration else { throw Rejection.unsupported }
                let segment = try resolve(line)
                guard segment != initialization else { throw Rejection.unsupported }
                segments.append(segment)
                pendingDuration = false
            }
        }
        guard let initialization, !segments.isEmpty, !pendingDuration else { throw Rejection.unsupported }
        return Media(initialization: initialization, segments: segments)
    }

    /// Byte ranges are sliced *after* a full validated initialization is normalized; never
    /// inspect or patch an arbitrary partial MP4 response. Multipart ranges are unsupported.
    static func range(_ header: String?, length: Int) throws -> Range<Int> {
        guard length > 0 else { throw Rejection.unsupported }
        guard let header else { return 0..<length }
        guard header.hasPrefix("bytes="), !header.contains(",") else { throw Rejection.unsupported }
        let pieces = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2 else { throw Rejection.unsupported }
        func integer(_ value: Substring) -> Int? {
            guard !value.isEmpty, value.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
            return Int(value)
        }
        if pieces[0].isEmpty {
            guard let suffix = integer(pieces[1]), suffix > 0 else { throw Rejection.unsupported }
            return max(0, length - suffix)..<length
        }
        guard let start = integer(pieces[0]), start < length else { throw Rejection.unsupported }
        if pieces[1].isEmpty { return start..<length }
        guard let end = integer(pieces[1]), end >= start else { throw Rejection.unsupported }
        return start..<(min(end, length - 1) + 1)
    }
}
