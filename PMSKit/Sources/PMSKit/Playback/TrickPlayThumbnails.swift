import Foundation

/// Backend-neutral thumbnail returned for a seek/scrub preview.
///
/// Keep this payload image-data based (not UIKit) so PMSKit and the player UI do not become
/// Plex-specific. Backends can provide a BIF frame, a Jellyfin chapter/sprite frame, or `nil`.
public struct TrickPlayThumbnail: Equatable, Sendable {
    public let timeMs: Int
    public let imageData: Data
    public let contentType: String?

    public init(timeMs: Int, imageData: Data, contentType: String? = nil) {
        self.timeMs = max(0, timeMs)
        self.imageData = imageData
        self.contentType = contentType
    }
}

/// Backend seam consumed by the custom player chrome. Implementations must be playback-passive:
/// they may fetch/cache thumbnail metadata, but must not rebuild media sessions or touch playback.
public protocol TrickPlayThumbnailProviding: Sendable {
    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail?
}

/// Graceful no-op provider for backends/items that do not currently expose trick-play images.
public struct UnavailableTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    public init() {}
    public func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? { nil }
}

public enum TrickPlayRequest {
    /// Plex BIF endpoint for the requested Part. `quality` is usually `sd` when the Part's
    /// `indexes` attribute advertises `sd`.
    public static func plexBIFIndex(server: URL,
                                    token: String,
                                    identity: ClientIdentity,
                                    partID: Int,
                                    quality: String = "sd") -> PlexRequest {
        let sanitizedQuality = quality.trimmingCharacters(in: .whitespacesAndNewlines)
        let qualityComponent = sanitizedQuality.isEmpty ? "sd" : sanitizedQuality
        return PlexRequest(url: server.appendingPathComponent("/library/parts/\(partID)/indexes/\(qualityComponent)"),
                           method: "GET",
                           queryItems: [URLQueryItem(name: "X-Plex-Token", value: token)],
                           headers: PlexHeaders.standard(identity: identity, token: nil))
    }
}

/// Parsed BIF index with frame byte ranges inside the original BIF payload.
public struct BIFIndex: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public let timeMs: Int
        public let data: Data

        public init(timeMs: Int, data: Data) {
            self.timeMs = max(0, timeMs)
            self.data = data
        }
    }

    public let version: UInt32
    public let frameIntervalMs: Int
    public let frames: [Frame]

    public init(version: UInt32, frameIntervalMs: Int, frames: [Frame]) {
        self.version = version
        self.frameIntervalMs = max(1, frameIntervalMs)
        self.frames = frames.sorted { $0.timeMs < $1.timeMs }
    }

    public func frame(nearMs targetMs: Int) -> Frame? {
        guard !frames.isEmpty else { return nil }
        let clamped = max(0, targetMs)
        var low = 0
        var high = frames.count - 1
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].timeMs < clamped {
                low = mid + 1
            } else {
                high = mid
            }
        }
        if low == 0 { return frames[0] }
        let before = frames[low - 1]
        let after = frames[low]
        return abs(after.timeMs - clamped) < abs(clamped - before.timeMs) ? after : before
    }
}

public enum BIFParserError: Error, Equatable, Sendable {
    case tooSmall
    case invalidMagic
    case unsupportedVersion(UInt32)
    case invalidImageCount(UInt32)
    case truncatedIndexTable
    case invalidFrameOffsets
    case noFrames
}

/// Parser for Roku/Plex BIF (Base Index Frame) files.
///
/// Layout used by Plex: 64-byte header, little-endian `version`, image count, timestamp multiplier
/// at offsets 8/12/16, followed by `count + 1` index rows of `(timestamp, byteOffset)`. The final
/// row is a sentinel whose offset marks the end of the last image. Timestamps are multiplied by the
/// header interval to produce milliseconds.
public enum BIFParser {
    private static let headerLength = 64
    private static let rowLength = 8
    private static let standardMagic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func parse(_ data: Data) throws -> BIFIndex {
        guard data.count >= headerLength else { throw BIFParserError.tooSmall }
        let bytes = [UInt8](data.prefix(headerLength))
        guard isRecognizedMagic(bytes) else { throw BIFParserError.invalidMagic }

        let version = data.readLittleEndianUInt32(at: 8)
        guard version == 0 else { throw BIFParserError.unsupportedVersion(version) }
        let count = data.readLittleEndianUInt32(at: 12)
        guard count > 0, count < 100_000 else { throw BIFParserError.invalidImageCount(count) }
        let intervalRaw = data.readLittleEndianUInt32(at: 16)
        let intervalMs = Int(intervalRaw == 0 ? 1000 : intervalRaw)

        let tableLength = Int(count + 1) * rowLength
        guard data.count >= headerLength + tableLength else { throw BIFParserError.truncatedIndexTable }

        var rows: [(timestamp: UInt32, offset: UInt32)] = []
        rows.reserveCapacity(Int(count + 1))
        for index in 0...Int(count) {
            let rowStart = headerLength + index * rowLength
            rows.append((timestamp: data.readLittleEndianUInt32(at: rowStart),
                         offset: data.readLittleEndianUInt32(at: rowStart + 4)))
        }

        var frames: [BIFIndex.Frame] = []
        frames.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let start = Int(rows[index].offset)
            let end = Int(rows[index + 1].offset)
            guard start >= headerLength + tableLength,
                  end <= data.count,
                  end > start else {
                throw BIFParserError.invalidFrameOffsets
            }
            let range = start..<end
            let timestamp = rows[index].timestamp
            let timeMs = timestamp == UInt32.max ? index * intervalMs : Int(timestamp) * intervalMs
            frames.append(BIFIndex.Frame(timeMs: timeMs, data: data.subdata(in: range)))
        }

        guard !frames.isEmpty else { throw BIFParserError.noFrames }
        return BIFIndex(version: version, frameIntervalMs: intervalMs, frames: frames)
    }

    private static func isRecognizedMagic(_ header: [UInt8]) -> Bool {
        guard header.count >= 8 else { return false }
        if Array(header.prefix(8)) == standardMagic { return true }
        // Some tools omit the leading PNG-style 0x89 while keeping ASCII "BIF"; accept that for
        // fixtures/older servers while still requiring the recognizable signature bytes.
        return header[0] == 0x42 && header[1] == 0x49 && header[2] == 0x46
    }
}

private extension Data {
    func readLittleEndianUInt32(at offset: Int) -> UInt32 {
        precondition(offset >= 0 && offset + 4 <= count)
        var value: UInt32 = 0
        for shift in 0..<4 {
            value |= UInt32(self[self.index(startIndex, offsetBy: offset + shift)]) << UInt32(shift * 8)
        }
        return value
    }
}
