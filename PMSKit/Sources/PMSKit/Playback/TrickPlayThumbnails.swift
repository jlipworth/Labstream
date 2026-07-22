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

/// Ordered, non-fatal provider fallback used by shared online/offline player entry points.
/// A missing or malformed higher-quality asset never prevents a lower-quality preview source.
public struct HierarchicalTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private let providers: [any TrickPlayThumbnailProviding]

    public init(_ providers: [any TrickPlayThumbnailProviding]) {
        self.providers = providers
    }

    public func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        for provider in providers {
            guard !Task.isCancelled else { return nil }
            if let thumbnail = await provider.thumbnail(nearMs: targetMs) { return thumbnail }
        }
        return nil
    }
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
        self.startMs = min(max(0, startMs), JellyfinTrickPlayLimits.maximumTimelineMs)
        self.durationMs = min(max(1, durationMs), JellyfinTrickPlayLimits.maximumSegmentDurationMs)
        self.tileDurationMs = min(max(1, tileDurationMs), JellyfinTrickPlayLimits.maximumFrameDurationMs)
        self.tileWidth = min(max(1, tileWidth), JellyfinTrickPlayLimits.maximumTileDimension)
        self.tileHeight = min(max(1, tileHeight), JellyfinTrickPlayLimits.maximumTileDimension)

        let boundedColumns = min(max(1, columns), JellyfinTrickPlayLimits.maximumLayoutDimension)
        self.columns = boundedColumns
        self.rows = min(max(1, rows),
                        min(JellyfinTrickPlayLimits.maximumLayoutDimension,
                            JellyfinTrickPlayLimits.maximumFrameCapacity / boundedColumns))
    }

    public var frameCapacity: Int {
        let (capacity, overflow) = columns.multipliedReportingOverflow(by: rows)
        return overflow ? JellyfinTrickPlayLimits.maximumFrameCapacity : capacity
    }

    public func frameIndex(nearMs targetMs: Int) -> Int {
        let localMs = targetMs <= startMs ? 0 : min(targetMs - startMs, durationMs - 1)
        return min(frameCapacity - 1, localMs / tileDurationMs)
    }

    public func frameTimeMs(frameIndex: Int) -> Int {
        let boundedIndex = min(max(0, frameIndex), frameCapacity - 1)
        let (offset, multiplicationOverflow) = boundedIndex.multipliedReportingOverflow(by: tileDurationMs)
        let boundedOffset = multiplicationOverflow ? durationMs - 1 : min(offset, durationMs - 1)
        let (timeMs, additionOverflow) = startMs.addingReportingOverflow(boundedOffset)
        return additionOverflow ? Int.max : timeMs
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
    case invalidMetadata
    case arithmeticOverflow
}

private enum JellyfinTrickPlayLimits {
    // These are deliberately generous compared with Jellyfin's usual 320x180, 10x10,
    // ten-second tiles, but keep hostile playlists from constructing nonsensical model math.
    static let maximumTileDimension = 16_384
    static let maximumLayoutDimension = 1_000
    static let maximumFrameCapacity = 100_000
    static let maximumSheetDimension = 65_536
    static let maximumFrameDurationMs = 7 * 24 * 60 * 60 * 1_000
    static let maximumSegmentDurationMs = 7 * 24 * 60 * 60 * 1_000
    static let maximumTimelineMs = 31 * 24 * 60 * 60 * 1_000
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
                pendingDurationMs = try parseEXTINF(line)
            } else if line.hasPrefix("#EXT-X-TILES:") {
                pendingTiles = try parseTiles(line)
            } else if line.hasPrefix("#") {
                continue
            } else if let durationMs = pendingDurationMs, let tileMeta = pendingTiles {
                let (nextStartMs, overflow) = currentStartMs.addingReportingOverflow(durationMs)
                guard !overflow else { throw JellyfinTrickPlayPlaylistParserError.arithmeticOverflow }
                guard nextStartMs <= JellyfinTrickPlayLimits.maximumTimelineMs else {
                    throw JellyfinTrickPlayPlaylistParserError.invalidMetadata
                }
                tiles.append(JellyfinTrickPlayTile(uri: line,
                                                   startMs: currentStartMs,
                                                   durationMs: durationMs,
                                                   tileDurationMs: tileMeta.durationMs,
                                                   tileWidth: tileMeta.width,
                                                   tileHeight: tileMeta.height,
                                                   columns: tileMeta.columns,
                                                   rows: tileMeta.rows))
                currentStartMs = nextStartMs
                pendingDurationMs = nil
                pendingTiles = nil
            }
        }

        guard !tiles.isEmpty else { throw JellyfinTrickPlayPlaylistParserError.empty }
        return JellyfinTrickPlayPlaylist(tiles: tiles)
    }

    private static func parseEXTINF(_ line: String) throws -> Int {
        let raw = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
        guard let seconds = Double(raw.trimmingCharacters(in: .whitespaces)) else {
            throw JellyfinTrickPlayPlaylistParserError.invalidMetadata
        }
        return try milliseconds(seconds: seconds,
                                maximum: JellyfinTrickPlayLimits.maximumSegmentDurationMs)
    }

    private static func parseTiles(_ line: String) throws -> (width: Int, height: Int, columns: Int, rows: Int, durationMs: Int) {
        let payload = line.dropFirst("#EXT-X-TILES:".count)
        var values: [String: String] = [:]
        for part in payload.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { values[pair[0].uppercased()] = pair[1] }
        }
        guard let resolution = parsePair(values["RESOLUTION"]),
              let layout = parsePair(values["LAYOUT"]),
              let durationSeconds = values["DURATION"].flatMap(Double.init),
              resolution.first > 0,
              resolution.second > 0,
              layout.first > 0,
              layout.second > 0 else {
            throw JellyfinTrickPlayPlaylistParserError.invalidMetadata
        }

        let (frameCapacity, frameCapacityOverflow) = layout.first.multipliedReportingOverflow(by: layout.second)
        let (sheetWidth, sheetWidthOverflow) = resolution.first.multipliedReportingOverflow(by: layout.first)
        let (sheetHeight, sheetHeightOverflow) = resolution.second.multipliedReportingOverflow(by: layout.second)
        guard !frameCapacityOverflow, !sheetWidthOverflow, !sheetHeightOverflow else {
            throw JellyfinTrickPlayPlaylistParserError.arithmeticOverflow
        }
        let durationMs = try milliseconds(seconds: durationSeconds,
                                          maximum: JellyfinTrickPlayLimits.maximumFrameDurationMs)
        let (representedDurationMs, representedDurationOverflow) = frameCapacity.multipliedReportingOverflow(by: durationMs)
        guard !representedDurationOverflow else {
            throw JellyfinTrickPlayPlaylistParserError.arithmeticOverflow
        }
        guard resolution.first <= JellyfinTrickPlayLimits.maximumTileDimension,
              resolution.second <= JellyfinTrickPlayLimits.maximumTileDimension,
              layout.first <= JellyfinTrickPlayLimits.maximumLayoutDimension,
              layout.second <= JellyfinTrickPlayLimits.maximumLayoutDimension,
              frameCapacity <= JellyfinTrickPlayLimits.maximumFrameCapacity,
              sheetWidth <= JellyfinTrickPlayLimits.maximumSheetDimension,
              sheetHeight <= JellyfinTrickPlayLimits.maximumSheetDimension,
              representedDurationMs <= JellyfinTrickPlayLimits.maximumSegmentDurationMs else {
            throw JellyfinTrickPlayPlaylistParserError.invalidMetadata
        }

        return (resolution.first, resolution.second, layout.first, layout.second, durationMs)
    }

    private static func parsePair(_ raw: String?) -> (first: Int, second: Int)? {
        guard let raw else { return nil }
        let components = raw.split(separator: "x", omittingEmptySubsequences: false)
        guard components.count == 2,
              let first = Int(components[0]),
              let second = Int(components[1]) else { return nil }
        return (first, second)
    }

    private static func milliseconds(seconds: Double, maximum: Int) throws -> Int {
        guard seconds.isFinite, seconds > 0, seconds <= Double(maximum) / 1_000 else {
            throw JellyfinTrickPlayPlaylistParserError.invalidMetadata
        }
        let milliseconds = (seconds * 1_000).rounded()
        guard milliseconds.isFinite, milliseconds >= 1, milliseconds <= Double(maximum) else {
            throw JellyfinTrickPlayPlaylistParserError.invalidMetadata
        }
        return Int(milliseconds)
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
    case timestampOverflow
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
            let timeMs = try timestampMilliseconds(timestamp: timestamp,
                                                   frameIndex: index,
                                                   intervalMs: intervalMs)
            frames.append(BIFIndex.Frame(timeMs: timeMs, data: data.subdata(in: range)))
        }

        guard !frames.isEmpty else { throw BIFParserError.noFrames }
        return BIFIndex(version: version, frameIntervalMs: intervalMs, frames: frames)
    }

    static func timestampMilliseconds(timestamp: UInt32,
                                      frameIndex: Int,
                                      intervalMs: Int) throws -> Int {
        let factor = timestamp == UInt32.max ? frameIndex : Int(timestamp)
        let (timeMs, overflow) = factor.multipliedReportingOverflow(by: intervalMs)
        guard !overflow else { throw BIFParserError.timestampOverflow }
        return timeMs
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
