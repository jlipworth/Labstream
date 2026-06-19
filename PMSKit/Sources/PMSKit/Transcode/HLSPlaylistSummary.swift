import Foundation

/// Lightweight parser for the parts of an HLS master playlist VisionPlay needs to reason about
/// adaptive playback. It intentionally does not validate full RFC 8216 syntax; it extracts
/// `#EXT-X-STREAM-INF` variant metadata and the following URI so deterministic tests and live
/// probes can distinguish a single-rendition PMS session from a true ABR ladder.
public struct HLSPlaylistSummary: Sendable, Equatable {
    public struct Variant: Sendable, Equatable {
        public let bandwidthBps: Int?
        public let resolution: String?
        public let codecs: String?
        public let uri: String?
    }

    public let variants: [Variant]

    public var isMasterPlaylist: Bool { !variants.isEmpty }
    public var isAdaptive: Bool { variants.count > 1 }

    public init(variants: [Variant]) {
        self.variants = variants
    }

    public static func parse(_ body: String) -> HLSPlaylistSummary {
        let lines = body.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }
        var variants: [Variant] = []
        var pendingAttributes: [String: String]?

        for line in lines where !line.isEmpty {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                pendingAttributes = parseAttributes(attrs)
                continue
            }
            guard let attrs = pendingAttributes else { continue }
            if line.hasPrefix("#") { continue }
            variants.append(Variant(
                bandwidthBps: attrs["BANDWIDTH"].flatMap(Int.init),
                resolution: attrs["RESOLUTION"],
                codecs: attrs["CODECS"],
                uri: line))
            pendingAttributes = nil
        }

        // Tolerate malformed masters where the stream-info tag has no following URI; useful for
        // diagnostics because it still proves PMS advertised a variant but the playlist is broken.
        if let attrs = pendingAttributes {
            variants.append(Variant(
                bandwidthBps: attrs["BANDWIDTH"].flatMap(Int.init),
                resolution: attrs["RESOLUTION"],
                codecs: attrs["CODECS"],
                uri: nil))
        }

        return HLSPlaylistSummary(variants: variants)
    }

    private static func parseAttributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false

        func flush() {
            let k = key.trimmingCharacters(in: .whitespaces)
            guard !k.isEmpty else { return }
            var v = value.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("\"") && v.hasSuffix("\"") && v.count >= 2 {
                v.removeFirst()
                v.removeLast()
            }
            result[k] = v
            key = ""
            value = ""
            readingKey = true
        }

        for ch in text {
            if readingKey {
                if ch == "=" {
                    readingKey = false
                } else if ch == "," {
                    flush()
                } else {
                    key.append(ch)
                }
            } else {
                if ch == "\"" { inQuotes.toggle() }
                if ch == "," && !inQuotes {
                    flush()
                } else {
                    value.append(ch)
                }
            }
        }
        flush()
        return result
    }
}
