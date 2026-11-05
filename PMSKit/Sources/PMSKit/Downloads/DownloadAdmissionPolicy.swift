import Foundation

/// Which concurrency lane a download occupies while it is admitted (downloads overhaul P4).
public enum DownloadAdmissionLane: String, Sendable, Equatable, Codable, CaseIterable {
    /// A byte-range or as-is file transfer (originals, rendered Plex Parts, converted Emby files).
    case staticFile
    /// A Plex optimize or Emby Convert job rendering on the server.
    case serverPreparation
    /// A live forward-only stream (Jellyfin transcode or remux, Emby remux).
    case liveForward
}

/// Who asked for a start. Explicit row actions are served before automatic ones; within a class
/// the oldest request goes first. The origin orders requests only; it never lifts a cap.
public enum DownloadAdmissionOrigin: Int, Sendable, Equatable, Comparable {
    case user = 0
    case automatic = 1

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A row that already uses a lane: observed active work, or a start the coordinator spawned whose
/// row is not observable as active yet (a reservation).
public struct DownloadAdmissionOccupant: Sendable, Equatable {
    public let id: String
    public let lane: DownloadAdmissionLane

    public init(id: String, lane: DownloadAdmissionLane) {
        self.id = id
        self.lane = lane
    }
}

/// A row waiting for a lane.
public struct DownloadAdmissionRequest: Sendable, Equatable {
    public let id: String
    public let lane: DownloadAdmissionLane
    public let origin: DownloadAdmissionOrigin
    public let requestedAt: TimeInterval
    /// Backoff: the request is not eligible before this time.
    public let eligibleAt: TimeInterval

    public init(id: String, lane: DownloadAdmissionLane, origin: DownloadAdmissionOrigin,
                requestedAt: TimeInterval, eligibleAt: TimeInterval? = nil) {
        self.id = id
        self.lane = lane
        self.origin = origin
        self.requestedAt = requestedAt
        self.eligibleAt = eligibleAt ?? requestedAt
    }
}

/// Concurrency limits derived from the user's simultaneous-download setting.
///
/// The setting bounds byte transfers. Server preparation (#414) is not a transfer: a submitted
/// Plex optimize or Emby Convert job renders on the server while the app is suspended, so prep
/// rows have their own fixed bound and never use a transfer slot. A finished render takes a
/// static slot only when it hands off (`mayHandOffToStatic`).
public struct DownloadAdmissionLimits: Sendable, Equatable {
    public static let supportedTotals = 1...5
    public static let defaultTotal = 3
    /// Server jobs submitted at once, whatever the transfer setting. The server's own transcoder
    /// settings decide how many render concurrently.
    public static let maximumServerPreparations = 5

    /// Whether a lane's occupants and grants count toward `maximumTotal`.
    public static func countsTowardTotal(_ lane: DownloadAdmissionLane) -> Bool {
        lane != .serverPreparation
    }

    public let maximumTotal: Int
    public let maximumByLane: [DownloadAdmissionLane: Int]

    public init(maximumTotal: Int) {
        let total = min(max(maximumTotal, Self.supportedTotals.lowerBound),
                        Self.supportedTotals.upperBound)
        self.maximumTotal = total
        self.maximumByLane = [
            .staticFile: max(1, total - 1),
            .serverPreparation: Self.maximumServerPreparations,
            .liveForward: 1,
        ]
    }
}

/// The one admission window every download start goes through (P4.1). Pure: the manager-owned
/// coordinator supplies current limits, observed occupancy and reservations and starts the grants.
public enum DownloadAdmissionPolicy {
    /// Backoff after a deferred start (backend unavailable): 1, 5, 15, 30, then 60 s.
    public static let deferralBackoffSeconds: [TimeInterval] = [1, 5, 15, 30, 60]

    public static func deferralDelay(afterAttempt step: Int) -> TimeInterval {
        let index = min(max(step, 0), deferralBackoffSeconds.count - 1)
        return deferralBackoffSeconds[index]
    }

    /// The lane a row that has not started yet will use.
    public static func lane(backend: DownloadBackendKind,
                            downloadLane: DownloadLane) -> DownloadAdmissionLane {
        switch downloadLane {
        case .original: return .staticFile
        case .compatibleRemux: return .liveForward
        case .optimize:
            return backend == .jellyfin ? .liveForward : .serverPreparation
        }
    }

    /// The requests to start now, in order. Occupants over a cap (work the OS or a poller still
    /// owned at relaunch, or a server-prep row that handed off into a full static lane) are counted
    /// as they are: nothing new enters that lane until it is back under its cap.
    public static func grants(
        limits: DownloadAdmissionLimits,
        occupants: [DownloadAdmissionOccupant],
        requests: [DownloadAdmissionRequest],
        now: TimeInterval,
        queuePaused: Bool,
        pauseExemptIDs: Set<String> = []
    ) -> [DownloadAdmissionRequest] {
        var seen = Set<String>()
        let distinct = occupants.filter { seen.insert($0.id).inserted }
        var counts = Dictionary(grouping: distinct, by: \.lane).mapValues(\.count)
        var total = distinct.filter { DownloadAdmissionLimits.countsTowardTotal($0.lane) }.count
        let ordered = requests
            .filter { !seen.contains($0.id) && $0.eligibleAt <= now }
            .filter { !queuePaused || pauseExemptIDs.contains($0.id) }
            .sorted {
                ($0.origin, $0.requestedAt, $0.id) < ($1.origin, $1.requestedAt, $1.id)
            }
        var result: [DownloadAdmissionRequest] = []
        var granted = Set<String>()
        for request in ordered {
            let countsTowardTotal = DownloadAdmissionLimits.countsTowardTotal(request.lane)
            if countsTowardTotal, total >= limits.maximumTotal { continue }
            guard granted.insert(request.id).inserted else { continue }
            let limit = limits.maximumByLane[request.lane] ?? 1
            guard counts[request.lane, default: 0] < limit else { continue }
            result.append(request)
            counts[request.lane, default: 0] += 1
            if countsTowardTotal { total += 1 }
        }
        return result
    }

    /// Whether an admitted row may move into `lane` before it creates server or encoder work
    /// (P4.5: a Plex original falling back to optimize, an Emby negotiation rerouted to Convert).
    /// The row's own occupancy is not counted against it.
    public static func mayEnter(_ lane: DownloadAdmissionLane, id: String,
                                occupants: [DownloadAdmissionOccupant],
                                limits: DownloadAdmissionLimits) -> Bool {
        var seen: Set<String> = [id]
        let others = occupants.filter { seen.insert($0.id).inserted }
        if DownloadAdmissionLimits.countsTowardTotal(lane),
           others.filter({ DownloadAdmissionLimits.countsTowardTotal($0.lane) }).count
            >= limits.maximumTotal { return false }
        let inLane = others.filter { $0.lane == lane }.count
        return inLane < (limits.maximumByLane[lane] ?? 1)
    }

    /// #414: whether a server-prep row whose render finished may start its byte transfer now. It
    /// needs a static slot and a transfer slot like any static start; its own prep occupancy is
    /// not counted against it. Until then it keeps its prep slot and waits.
    public static func mayHandOffToStatic(id: String, occupants: [DownloadAdmissionOccupant],
                                          limits: DownloadAdmissionLimits) -> Bool {
        mayEnter(.staticFile, id: id, occupants: occupants, limits: limits)
    }

    /// The earliest time a currently ineligible request becomes eligible, for the pump's timer.
    public static func nextEligibleTime(requests: [DownloadAdmissionRequest],
                                        now: TimeInterval) -> TimeInterval? {
        requests.map(\.eligibleAt).filter { $0 > now }.min()
    }
}
