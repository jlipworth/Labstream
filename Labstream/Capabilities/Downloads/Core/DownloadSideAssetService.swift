import Foundation
import ImageIO
import PMSKit
#if canImport(Darwin)
import Darwin
#endif

/// Optional payload classes owned by one exact offline-download attempt and selected source.
/// Keeping this vocabulary independent of the work registry lets repair accounting distinguish
/// assets that share a task (for example all chapter images) without falling back to row identity.
enum DownloadSideAssetKind: String, CaseIterable, Hashable, Sendable {
    case poster
    case plexBIF
    case embyBIF
    case jellyfinTrickPlay
    case chapterImages
    case textSubtitles
}

/// Hashable projection of `OfflineSideAssetSourceIdentity`. The persisted model deliberately only
/// promises Equatable; retry bookkeeping still needs the complete source identity in its key.
private struct DownloadSideAssetSourceKey: Hashable, Sendable {
    let backendKind: String?
    let backendBaseURLString: String?
    let backendServerID: String?
    let mediaSourceID: String?
    let mediaIndex: Int?
    let partIndex: Int?
    let sourcePartID: Int?
    let downloadLane: String?
    let serverPreparedVersion: Bool

    init(_ source: OfflineSideAssetSourceIdentity) {
        backendKind = source.backendKind?.rawValue
        backendBaseURLString = source.backendBaseURLString
        backendServerID = source.backendServerID
        mediaSourceID = source.mediaSourceID
        mediaIndex = source.mediaIndex
        partIndex = source.partIndex
        sourcePartID = source.sourcePartID
        downloadLane = source.downloadLane?.rawValue
        serverPreparedVersion = source.serverPreparedVersion
    }
}

/// Exact retry authority for one optional payload class. A replacement attempt or selected source
/// receives a fresh budget; neither can inherit a predecessor's failures.
struct DownloadSideAssetRetryIdentity: Hashable, Sendable {
    let attemptKey: DownloadAttemptKey
    private let source: DownloadSideAssetSourceKey
    let kind: DownloadSideAssetKind
    let resource: String?

    init(attemptKey: DownloadAttemptKey,
         source: OfflineSideAssetSourceIdentity,
         kind: DownloadSideAssetKind,
         resource: String? = nil) {
        self.attemptKey = attemptKey
        self.source = DownloadSideAssetSourceKey(source)
        self.kind = kind
        self.resource = resource
    }
}

/// Launch-scoped retry accounting. Callers charge only immediately before a transport dispatch;
/// inventory scans, missing auth, request-construction failures, and registry coalescing are free.
struct DownloadSideAssetRetryBudget {
    static let defaultMaximumDispatches = 5

    private(set) var dispatches: [DownloadSideAssetRetryIdentity: Int] = [:]

    func canDispatch(_ identity: DownloadSideAssetRetryIdentity,
                     maximum: Int = Self.defaultMaximumDispatches) -> Bool {
        (dispatches[identity] ?? 0) < maximum
    }

    @discardableResult
    mutating func chargeDispatch(_ identity: DownloadSideAssetRetryIdentity,
                                 maximum: Int = Self.defaultMaximumDispatches) -> Bool {
        guard canDispatch(identity, maximum: maximum) else { return false }
        dispatches[identity, default: 0] += 1
        return true
    }
}

/// The complete set of repairable optional payload classes derivable from a persisted completed
/// row. Availability that only the server can answer (Plex BIF/subtitle streams) is still included;
/// the bounded exact-source budget prevents repeated source refreshes from becoming unbounded.
enum DownloadSideAssetRepairInventory {
    static func missingKinds(record: DownloadRecord,
                             fileExists: (String) -> Bool,
                             jellyfinPlaylistTiles: (String) -> [String]? = { _ in nil })
        -> Set<DownloadSideAssetKind> {
        guard let metadata = record.metadata else { return [] }
        let item = metadata.makeMediaItem()
        let backend = metadata.resolvedBackendKind(ratingKey: record.ratingKey)
        var result: Set<DownloadSideAssetKind> = []

        if DownloadSideAssetPolicy.offlinePosterRef(for: item)?.isEmpty == false,
           metadata.posterRelativePath.map(fileExists) != true {
            result.insert(.poster)
        }

        switch backend {
        case .plex:
            if metadata.plexBIFRelativePath.map(fileExists) != true { result.insert(.plexBIF) }
            // The persisted metadata cannot enumerate streams that were never cached. A bounded
            // source refresh is the only complete repair inventory for a completed Plex row.
            result.insert(.textSubtitles)
        case .jellyfin:
            let playlistMissing = metadata.jellyfinTrickPlayPlaylistRelativePath
                .map(fileExists) != true
            // The caller's fileExists closure is also the exact-attempt ownership/safe-path
            // proof. Never hand an untrusted persisted relative path to a playlist loader
            // until that proof succeeds.
            let referencedTiles = playlistMissing ? nil
                : metadata.jellyfinTrickPlayPlaylistRelativePath
                    .flatMap(jellyfinPlaylistTiles)
            let playlistInventoryUnreadable = metadata.jellyfinTrickPlayPlaylistRelativePath != nil
                && !playlistMissing && referencedTiles == nil
            let referencedTileMissing = referencedTiles?
                .contains(where: { !fileExists($0) }) == true
            if metadata.mediaSourceID?.isEmpty == false,
               (playlistMissing || playlistInventoryUnreadable || referencedTileMissing
                || (metadata.jellyfinTrickPlayTileRelativePaths ?? []).contains(where: {
                    !fileExists($0)
                })) {
                result.insert(.jellyfinTrickPlay)
            }
            if metadata.mediaSourceID?.isEmpty == false { result.insert(.textSubtitles) }
        case .emby:
            if metadata.mediaSourceID?.isEmpty == false,
               metadata.embyBIFRelativePath.map(fileExists) != true {
                result.insert(.embyBIF)
            }
            if metadata.mediaSourceID?.isEmpty == false { result.insert(.textSubtitles) }
        }

        let expectedChapterIndexes = Set((item.chapters ?? []).enumerated().compactMap {
            $0.element.thumb?.isEmpty == false ? $0.offset : nil
        })
        let presentChapterIndexes = Set((metadata.chapterImageRelativePaths ?? [:]).compactMap {
            fileExists($0.value) ? $0.key : nil
        })
        if !expectedChapterIndexes.subtracting(presentChapterIndexes).isEmpty {
            result.insert(.chapterImages)
        }

        if let tracks = metadata.offlineTextSubtitles,
           tracks.contains(where: { !fileExists($0.relativePath) }) {
            result.insert(.textSubtitles)
        }
        return result
    }

    /// Concrete transport resources needed to repair one missing kind. The completed-row scanner
    /// uses these exact discriminators, matching transport admission, so exhausted multi-file
    /// resources stop being offered while unrelated chapter/subtitle files retain their own budget.
    static func retryResources(for kind: DownloadSideAssetKind,
                               record: DownloadRecord,
                               fileExists: (String) -> Bool,
                               chapterResource: (Int) -> String) -> [String?] {
        guard let metadata = record.metadata else { return [] }
        switch kind {
        case .poster, .embyBIF:
            return [nil]
        case .plexBIF:
            // Plex does not persist Part/BIF availability; every repair begins with source detail.
            return ["source-metadata"]
        case .jellyfinTrickPlay:
            // The playlist is the manifest required to discover/rebuild every missing tile.
            return ["playlist"]
        case .textSubtitles:
            // Source detail is required to rediscover both never-cached and missing tracks.
            return ["source-metadata"]
        case .chapterImages:
            let chapters = metadata.makeMediaItem().chapters ?? []
            return chapters.enumerated().compactMap { index, chapter in
                guard chapter.thumb?.isEmpty == false else { return nil }
                if let relative = metadata.chapterImageRelativePaths?[index], fileExists(relative) {
                    return nil
                }
                return chapterResource(index)
            }
        }
    }
}

enum DownloadSideAssetPayloadKind: Sendable {
    case image
    case bif
    case textSubtitle
    case jellyfinPlaylist
}

/// One task's publication delta. Multi-file kinds accumulate here and issue one store mutation
/// after every file has either promoted or failed, avoiding one JSON snapshot per tile/track.
struct DownloadSideAssetPublicationBatch: Sendable, Equatable {
    var chapterImages: [Int: String] = [:]
    var textSubtitles: [OfflineTextSubtitleTrack] = []
    var jellyfinTiles: [String] = []
    var jellyfinPlaylist: String?

    func apply(to metadata: inout OfflineMetadata) {
        if !chapterImages.isEmpty {
            var merged = metadata.chapterImageRelativePaths ?? [:]
            merged.merge(chapterImages) { _, current in current }
            metadata.chapterImageRelativePaths = merged
        }
        if !textSubtitles.isEmpty {
            var merged = metadata.offlineTextSubtitles ?? []
            for track in textSubtitles where !merged.contains(where: {
                $0.relativePath == track.relativePath
            }) {
                merged.append(track)
            }
            metadata.offlineTextSubtitles = merged
        }
        if !jellyfinTiles.isEmpty {
            var merged = metadata.jellyfinTrickPlayTileRelativePaths ?? []
            for path in jellyfinTiles where !merged.contains(path) { merged.append(path) }
            metadata.jellyfinTrickPlayTileRelativePaths = merged
        }
        if let jellyfinPlaylist {
            metadata.jellyfinTrickPlayPlaylistRelativePath = jellyfinPlaylist
        }
    }
}

/// Non-main payload preparation boundary. Validation happens before an atomic staging write, so
/// corrupt HTML/error bodies can never be promoted into the offline bundle.
enum DownloadSideAssetService {
    static func parseJellyfinPlaylist(_ data: Data) async
        -> (text: String, playlist: JellyfinTrickPlayPlaylist)? {
        await Task.detached(priority: .utility) {
            guard let text = String(data: data, encoding: .utf8),
                  let playlist = try? JellyfinTrickPlayPlaylistParser.parse(text) else { return nil }
            return (text, playlist)
        }.value
    }

    static func prepare(_ data: Data,
                        as kind: DownloadSideAssetPayloadKind,
                        at stagingURL: URL,
                        executionProbe: (@Sendable (Bool) -> Void)? = nil) async -> Bool {
        await Task.detached(priority: .utility) {
            #if canImport(Darwin)
            executionProbe?(pthread_main_np() != 0)
            #else
            executionProbe?(false)
            #endif
            guard validate(data, as: kind) else { return false }
            do {
                try data.write(to: stagingURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }.value
    }

    nonisolated static func validate(_ data: Data, as kind: DownloadSideAssetPayloadKind) -> Bool {
        guard !data.isEmpty else { return false }
        switch kind {
        case .image:
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  CGImageSourceGetCount(source) > 0 else { return false }
            return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
        case .bif:
            return (try? BIFParser.parse(data)) != nil
        case .textSubtitle:
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return !OfflineTextSubtitleParser.parse(text).isEmpty
        case .jellyfinPlaylist:
            guard let text = String(data: data, encoding: .utf8) else { return false }
            return (try? JellyfinTrickPlayPlaylistParser.parse(text)) != nil
        }
    }
}
