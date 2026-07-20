import Foundation

/// Server-authoritative watched state used by the one-time season planner. Missing backend data is
/// deliberately distinct from unwatched so an incomplete payload can never expand a batch.
public enum SeasonEpisodeWatchedState: String, Sendable, Equatable, Codable {
    case watched
    case unwatched
    case unavailable

    /// Maps a raw view count to watched state. `nilMeansUnwatched` captures the backend's
    /// semantic for a missing count: Jellyfin/Emby expose a genuinely three-valued
    /// `UserData.Played`, so a missing value is unknown (`.unavailable`); Plex omits `viewCount`
    /// entirely for never-watched items, so for Plex a missing value means `.unwatched`.
    public init(viewCount: Int?, nilMeansUnwatched: Bool) {
        guard let viewCount else {
            self = nilMeansUnwatched ? .unwatched : .unavailable
            return
        }
        self = viewCount > 0 ? .watched : .unwatched
    }

    /// Convenience for callers that know their backend. Only Plex treats a missing view count
    /// as unwatched; every other backend preserves the three-valued semantic.
    public init(viewCount: Int?, backend: MediaBackendID) {
        self.init(viewCount: viewCount, nilMeansUnwatched: backend == .plex)
    }

    /// Retained three-valued mapping (missing → `.unavailable`) for backends whose payload is
    /// genuinely three-valued.
    public init(viewCount: Int?) {
        self.init(viewCount: viewCount, nilMeansUnwatched: false)
    }
}

public enum SeasonDownloadEpisodeScope: Sendable, Hashable {
    case all
    case unwatched
}

public struct SeasonDownloadSelectionSummary: Sendable, Equatable {
    public let selectedIndices: [Int]
    public let watchedCount: Int
    public let unwatchedCount: Int
    public let unavailableCount: Int

    public init(selectedIndices: [Int], watchedCount: Int, unwatchedCount: Int,
                unavailableCount: Int) {
        self.selectedIndices = selectedIndices
        self.watchedCount = watchedCount
        self.unwatchedCount = unwatchedCount
        self.unavailableCount = unavailableCount
    }
}

public enum SeasonDownloadSelectionPolicy {
    public static func select(states: [SeasonEpisodeWatchedState],
                              scope: SeasonDownloadEpisodeScope) -> SeasonDownloadSelectionSummary {
        var selected: [Int] = []
        var watched = 0
        var unwatched = 0
        var unavailable = 0
        for (index, state) in states.enumerated() {
            switch state {
            case .watched: watched += 1
            case .unwatched: unwatched += 1
            case .unavailable: unavailable += 1
            }
            if scope == .all || (scope == .unwatched && state == .unwatched) {
                selected.append(index)
            }
        }
        return .init(selectedIndices: selected, watchedCount: watched,
                     unwatchedCount: unwatched, unavailableCount: unavailable)
    }
}

public enum SeasonDownloadExistingRowAction: Sendable, Equatable {
    case add
    case alreadyAvailable
    case alreadyPlanned
    case preservePaused
    case retryFailed
    case skipDeletionPending
}

public enum SeasonDownloadDedupPolicy {
    public static func action(status: DownloadStatus?, deletionPending: Bool = false)
        -> SeasonDownloadExistingRowAction {
        if deletionPending { return .skipDeletionPending }
        guard let status else { return .add }
        switch status {
        case .complete, .unverified: return .alreadyAvailable
        case .queued, .preparing, .downloading: return .alreadyPlanned
        case .paused: return .preservePaused
        case .failed: return .retryFailed
        }
    }
}

/// A quality point used to compare heterogeneous server-prepared versions. Bitrate is kbps.
public struct SeasonDownloadQualityPoint: Sendable, Equatable {
    public let width: Int?
    public let height: Int?
    public let bitrateKbps: Int?

    public init(width: Int?, height: Int?, bitrateKbps: Int?) {
        self.width = width
        self.height = height
        self.bitrateKbps = bitrateKbps
    }

    public var hasKnownDimension: Bool {
        (width ?? 0) > 0 || (height ?? 0) > 0 || (bitrateKbps ?? 0) > 0
    }
}

public enum SeasonDownloadExistingVersionMatchPolicy {
    /// Returns the nearest playable version overall. Resolution and bitrate use proportional
    /// (log-ratio) distance so overshooting and undershooting are treated symmetrically. Missing
    /// dimensions are ignored; candidates with no comparable facts are never auto-selected.
    public static func nearestIndex(requested: SeasonDownloadQualityPoint,
                                    candidates: [(quality: SeasonDownloadQualityPoint,
                                                  sizeBytes: Int?, playable: Bool)]) -> Int? {
        guard requested.hasKnownDimension else { return nil }
        return candidates.enumerated().compactMap { index, candidate -> (Int, Double, Int)? in
            guard candidate.playable else { return nil }
            let distance = qualityDistance(requested, candidate.quality)
            guard let distance else { return nil }
            return (index, distance, candidate.sizeBytes ?? Int.max)
        }.min {
            if abs($0.1 - $1.1) > 0.000_001 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }?.0
    }

    private static func qualityDistance(_ lhs: SeasonDownloadQualityPoint,
                                        _ rhs: SeasonDownloadQualityPoint) -> Double? {
        var distances: [Double] = []
        // Height is the most stable resolution measure for widescreen and unusual aspect ratios;
        // use width only when height is unavailable on either side.
        if let a = positive(lhs.height), let b = positive(rhs.height) {
            distances.append(abs(log(Double(b) / Double(a))))
        } else if let a = positive(lhs.width), let b = positive(rhs.width) {
            distances.append(abs(log(Double(b) / Double(a))))
        }
        if let a = positive(lhs.bitrateKbps), let b = positive(rhs.bitrateKbps) {
            distances.append(abs(log(Double(b) / Double(a))))
        }
        guard !distances.isEmpty else { return nil }
        return distances.reduce(0, +) / Double(distances.count)
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

public struct SeasonDownloadStorageSummary: Sendable, Equatable {
    public let knownBytes: Int
    public let unknownCount: Int

    public init(knownBytes: Int, unknownCount: Int) {
        self.knownBytes = knownBytes
        self.unknownCount = unknownCount
    }
}

public enum SeasonDownloadStoragePolicy {
    public static func summarize(_ estimates: [Int?]) -> SeasonDownloadStorageSummary {
        estimates.reduce(into: .init(knownBytes: 0, unknownCount: 0)) { result, estimate in
            if let estimate, estimate > 0 {
                result = .init(knownBytes: result.knownBytes + estimate,
                               unknownCount: result.unknownCount)
            } else {
                result = .init(knownBytes: result.knownBytes,
                               unknownCount: result.unknownCount + 1)
            }
        }
    }
}

public enum SeasonDownloadAdmissionLane: String, Sendable, Equatable, Codable {
    case staticFile
    case serverPreparation
    case liveForward
}

public struct SeasonDownloadAdmissionCandidate: Sendable, Equatable {
    public let id: String
    public let lane: SeasonDownloadAdmissionLane

    public init(id: String, lane: SeasonDownloadAdmissionLane) {
        self.id = id
        self.lane = lane
    }
}

public enum SeasonDownloadAdmissionPolicy {
    public static let maximumTotal = 3
    public static let maximumByLane: [SeasonDownloadAdmissionLane: Int] = [
        .staticFile: 2,
        .serverPreparation: 1,
        .liveForward: 1,
    ]

    public static func lane(backend: DownloadBackendKind,
                            downloadLane: DownloadLane) -> SeasonDownloadAdmissionLane {
        switch downloadLane {
        case .original: return .staticFile
        case .compatibleRemux: return .liveForward
        case .optimize:
            return backend == .jellyfin ? .liveForward : .serverPreparation
        }
    }

    public static func admitted(pending: [SeasonDownloadAdmissionCandidate],
                                active: [SeasonDownloadAdmissionCandidate])
        -> [SeasonDownloadAdmissionCandidate] {
        var counts = Dictionary(grouping: active, by: \.lane).mapValues(\.count)
        var total = active.count
        var result: [SeasonDownloadAdmissionCandidate] = []
        for candidate in pending {
            guard total < maximumTotal else { break }
            let limit = maximumByLane[candidate.lane] ?? 1
            guard counts[candidate.lane, default: 0] < limit else { continue }
            result.append(candidate)
            counts[candidate.lane, default: 0] += 1
            total += 1
        }
        return result
    }
}
