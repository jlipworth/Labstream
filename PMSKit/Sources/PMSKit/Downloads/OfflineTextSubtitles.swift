import Foundation

/// A locally-cached external text subtitle track for offline playback.
/// `relativePath` is relative to the Downloads base directory; no token-bearing URL is persisted.
public struct OfflineTextSubtitleTrack: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public var displayName: String
    public var language: String?
    public var codec: String?
    public var role: SubtitleStreamRole?
    public var relativePath: String

    public init(id: Int, displayName: String, language: String? = nil,
                codec: String? = nil, role: SubtitleStreamRole? = nil,
                relativePath: String) {
        self.id = id
        self.displayName = displayName
        self.language = language
        self.codec = codec
        self.role = role
        self.relativePath = relativePath
    }
}

public struct OfflineTextSubtitleCue: Sendable, Equatable {
    public let startMs: Int
    public let endMs: Int
    public let text: String

    public init(startMs: Int, endMs: Int, text: String) {
        self.startMs = max(0, startMs)
        self.endMs = max(self.startMs, endMs)
        self.text = text
    }

    public func contains(_ timeMs: Int) -> Bool {
        timeMs >= startMs && timeMs < endMs
    }
}

public enum OfflineTextSubtitleParser {
    public static func parse(_ text: String) -> [OfflineTextSubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.contains("WEBVTT") || normalized.contains("-->")
            ? parseBlocks(normalized)
            : []
    }

    private static func parseBlocks(_ text: String) -> [OfflineTextSubtitleCue] {
        text.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("WEBVTT") && !$0.hasPrefix("NOTE") }
            guard !lines.isEmpty else { return nil }
            let timingIndex = lines.firstIndex { $0.contains("-->") }
            guard let timingIndex,
                  let (start, end) = parseTimingLine(lines[timingIndex]) else { return nil }
            let payload = lines.dropFirst(timingIndex + 1)
                .map(stripMarkup)
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty else { return nil }
            return OfflineTextSubtitleCue(startMs: start, endMs: end, text: payload)
        }.sorted { $0.startMs < $1.startMs }
    }

    private static func parseTimingLine(_ line: String) -> (Int, Int)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = parseTimestamp(parts[0]),
              let end = parseTimestamp(parts[1].split(separator: " ").first.map(String.init) ?? parts[1]) else { return nil }
        return (start, end)
    }

    private static func parseTimestamp(_ raw: String) -> Int? {
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        let parts = clean.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsPart = parts.last ?? ""
        let secPieces = secondsPart.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard let seconds = Int(secPieces.first ?? "") else { return nil }
        let fraction = secPieces.indices.contains(1) ? secPieces[1] : "0"
        let millis = Int((fraction + "000").prefix(3)) ?? 0
        if parts.count == 3 {
            guard let hours = Int(parts[0]), let minutes = Int(parts[1]) else { return nil }
            return ((hours * 3600 + minutes * 60 + seconds) * 1000) + millis
        } else {
            guard let minutes = Int(parts[0]) else { return nil }
            return ((minutes * 60 + seconds) * 1000) + millis
        }
    }

    private static func stripMarkup(_ text: String) -> String {
        text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
    }
}

public enum OfflineTextSubtitleCachePlanner {
    public static let compatibleTextCodecs: Set<String> = ["srt", "subrip", "webvtt", "vtt"]

    public static func isCompatibleTextSubtitle(_ stream: Stream) -> Bool {
        guard stream.kind == .subtitle else { return false }
        guard let codec = stream.codec?.lowercased(), compatibleTextCodecs.contains(codec) else { return false }
        return true
    }

    public static func fileExtension(for stream: Stream) -> String {
        switch stream.codec?.lowercased() {
        case "webvtt", "vtt": return "vtt"
        case "srt", "subrip": return "srt"
        default: return "vtt"
        }
    }

    public static func displayName(for stream: Stream, fallbackIndex: Int) -> String {
        let base = stream.displayTitle
            ?? stream.extendedDisplayTitle
            ?? stream.language
            ?? stream.languageCode
            ?? "Subtitle \(fallbackIndex + 1)"
        var label = base
        if stream.subtitleRole != .full, let role = stream.roleLabel,
           !label.lowercased().contains(role.lowercased()) {
            label += " (\(role))"
        }
        if stream.external == true, !label.lowercased().contains("external") {
            label += " (External)"
        }
        return label
    }

    public static func track(for stream: Stream, relativePath: String, fallbackIndex: Int) -> OfflineTextSubtitleTrack? {
        guard isCompatibleTextSubtitle(stream) else { return nil }
        return OfflineTextSubtitleTrack(id: stream.id,
                                        displayName: displayName(for: stream, fallbackIndex: fallbackIndex),
                                        language: stream.languageCode ?? stream.languageTag ?? stream.language,
                                        codec: stream.codec,
                                        role: stream.subtitleRole,
                                        relativePath: relativePath)
    }
}
