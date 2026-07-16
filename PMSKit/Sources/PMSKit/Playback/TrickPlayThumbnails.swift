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

/// Chooses the sparse preview frame whose capture begins at or before the scrub target.
/// `sortedFrameTimesMs` must be ascending. Targets before the first frame use the first available
/// image, matching the graceful fallback used by chapter-image preview providers.
public enum SparseTrickPlayFrameSelectionPolicy {
    public static func frameIndex(nearMs targetMs: Int,
                                  sortedFrameTimesMs: [Int]) -> Int? {
        guard !sortedFrameTimesMs.isEmpty else { return nil }
        let clamped = max(0, targetMs)
        return sortedFrameTimesMs.indices.last {
            sortedFrameTimesMs[$0] <= clamped
        } ?? sortedFrameTimesMs.startIndex
    }
}

public struct JellyfinTrickPlayTile: Equatable, Sendable {
    public let uri: String
    public let startMs: Int
    public let durationMs: Int
    public let tileDurationMs: Int
    public let tileWidth: Int
    public let tileHeight: Int
    public let columns: Int
    public let rows: Int

    public init(uri: String,
                startMs: Int,
                durationMs: Int,
                tileDurationMs: Int,
                tileWidth: Int,
                tileHeight: Int,
                columns: Int,
                rows: Int) {
        self.uri = uri
        self.startMs = max(0, startMs)
        self.durationMs = max(1, durationMs)
        self.tileDurationMs = max(1, tileDurationMs)
        self.tileWidth = max(1, tileWidth)
        self.tileHeight = max(1, tileHeight)
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    public var frameCapacity: Int { columns * rows }

    public func frameIndex(nearMs targetMs: Int) -> Int {
        let localMs = min(max(0, targetMs - startMs), max(0, durationMs - 1))
        return min(frameCapacity - 1, localMs / tileDurationMs)
    }

    public func frameTimeMs(frameIndex: Int) -> Int {
        startMs + min(max(0, frameIndex), frameCapacity - 1) * tileDurationMs
    }
}

public struct JellyfinTrickPlayFrame: Equatable, Sendable {
    public let tile: JellyfinTrickPlayTile
    public let frameIndex: Int

    public var timeMs: Int { tile.frameTimeMs(frameIndex: frameIndex) }
    public var column: Int { frameIndex % tile.columns }
    public var row: Int { frameIndex / tile.columns }
}

public struct JellyfinTrickPlayPlaylist: Equatable, Sendable {
    public let tiles: [JellyfinTrickPlayTile]

    public init(tiles: [JellyfinTrickPlayTile]) {
        self.tiles = tiles.sorted { $0.startMs < $1.startMs }
    }

    public func frame(nearMs targetMs: Int) -> JellyfinTrickPlayFrame? {
        guard !tiles.isEmpty else { return nil }
        let clamped = max(0, targetMs)
        let tile = tiles.last { $0.startMs <= clamped } ?? tiles[0]
        return JellyfinTrickPlayFrame(tile: tile, frameIndex: tile.frameIndex(nearMs: clamped))
    }
}

public enum JellyfinTrickPlayPlaylistParserError: Error, Equatable, Sendable {
    case empty
}

/// Parser for Jellyfin's image-only trickplay HLS playlist. Jellyfin emits tile sheets as
/// `#EXT-X-TILES:RESOLUTION=320x180,LAYOUT=10x10,DURATION=10` followed by a relative JPEG URI.
/// `EXTINF` covers the duration represented by the sheet, while `DURATION` is the per-frame
/// spacing inside that sheet.
public enum JellyfinTrickPlayPlaylistParser {
    public static func parse(_ text: String) throws -> JellyfinTrickPlayPlaylist {
        var currentStartMs = 0
        var pendingDurationMs: Int?
        var pendingTiles: (width: Int, height: Int, columns: Int, rows: Int, durationMs: Int)?
        var tiles: [JellyfinTrickPlayTile] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#EXTINF:") {
                pendingDurationMs = parseEXTINF(line)
            } else if line.hasPrefix("#EXT-X-TILES:") {
                pendingTiles = parseTiles(line)
            } else if line.hasPrefix("#") {
                continue
            } else if let durationMs = pendingDurationMs, let tileMeta = pendingTiles {
                tiles.append(JellyfinTrickPlayTile(uri: line,
                                                   startMs: currentStartMs,
                                                   durationMs: durationMs,
                                                   tileDurationMs: tileMeta.durationMs,
                                                   tileWidth: tileMeta.width,
                                                   tileHeight: tileMeta.height,
                                                   columns: tileMeta.columns,
                                                   rows: tileMeta.rows))
                currentStartMs += durationMs
                pendingDurationMs = nil
                pendingTiles = nil
            }
        }

        guard !tiles.isEmpty else { throw JellyfinTrickPlayPlaylistParserError.empty }
        return JellyfinTrickPlayPlaylist(tiles: tiles)
    }

    private static func parseEXTINF(_ line: String) -> Int? {
        let raw = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
        guard let seconds = Double(raw.trimmingCharacters(in: .whitespaces)) else { return nil }
        return max(1, Int((seconds * 1000).rounded()))
    }

    private static func parseTiles(_ line: String) -> (width: Int, height: Int, columns: Int, rows: Int, durationMs: Int)? {
        let payload = line.dropFirst("#EXT-X-TILES:".count)
        var values: [String: String] = [:]
        for part in payload.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0].uppercased()] = pair[1] }
        }
        guard let resolution = values["RESOLUTION"]?.split(separator: "x").compactMap({ Int($0) }),
              resolution.count == 2,
              let layout = values["LAYOUT"]?.split(separator: "x").compactMap({ Int($0) }),
              layout.count == 2,
              let durationSeconds = values["DURATION"].flatMap(Double.init) else { return nil }
        return (resolution[0], resolution[1], layout[0], layout[1], max(1, Int((durationSeconds * 1000).rounded())))
    }
}


/// Pure helpers for caching Jellyfin trickplay playlists offline. Keeps token-stripping and
/// storage estimates headlessly testable outside the app target.
public enum JellyfinTrickPlayOfflineCachePlanner {
    public static func sanitizedPlaylist(_ text: String,
                                         tileFilenamesByURI: [String: String]) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { rawLine -> String in
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return String(rawLine) }
            // A cached tile maps to its local filename. A tile that failed to download is absent from
            // the map; fall back to a query-STRIPPED basename so a token-bearing server URI
            // (`tile.jpg?ApiKey=…`) can never survive into the persisted playlist — otherwise a single
            // failed tile would either leak a token or trip the caller's `apikey=` guard and void the
            // whole playlist. The dropped tile simply has no offline thumbnail.
            return tileFilenamesByURI[line] ?? tokenFreeBasename(line)
        }.joined(separator: "\n")
    }

    /// Last path component of a tile URI with any query string removed. `URL(fileURLWithPath:)`
    /// treats `?` as a literal path character, so the query must be stripped explicitly.
    private static func tokenFreeBasename(_ line: String) -> String {
        let withoutQuery = line.split(separator: "?", maxSplits: 1).first.map(String.init) ?? line
        return URL(fileURLWithPath: withoutQuery).lastPathComponent
    }

    public static func estimatedTileBytes(durationMs: Int?) -> Int {
        guard let durationMs, durationMs > 0 else { return 0 }
        let sheetCount = max(1, Int(ceil(Double(durationMs) / 1_000_000.0)))
        return sheetCount * 300_000
    }
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
