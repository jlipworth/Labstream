import Foundation

/// Where an attempt is in its life (downloads overhaul P3a). Cases carry no payload: the facts
/// that used to hide inside a status (why it paused, how many truncations, what it owes a server)
/// live in `DownloadAttemptHistory` and the row's facets. `DownloadStatus` is derived from this.
public enum DownloadLifecycle: String, Codable, Sendable, CaseIterable {
    /// Created but not admitted (season rows today; every new row once admission lands in P4).
    case planned
    /// Admitted; no transfer task exists yet.
    case admitted
    /// A Plex optimize or Emby Convert job is preparing the source on the server.
    case serverPrep
    /// URLSession work is live or being rebuilt.
    case transferring
    /// The body is complete; capture, validation or publication is pending (B10).
    case finalizing
    case complete
    case unverified
    case paused
    case failed

    /// The status older binaries, diagnostics and the UI read.
    public var derivedStatus: DownloadStatus {
        switch self {
        case .planned, .admitted: return .queued
        case .serverPrep: return .preparing
        case .transferring, .finalizing: return .downloading
        case .complete: return .complete
        case .unverified: return .unverified
        case .paused: return .paused
        case .failed: return .failed
        }
    }

    public var isTerminal: Bool { self == .complete || self == .unverified || self == .failed }

    /// Structural derivation for a row written before lifecycle existed (R2-6): status only, no
    /// effects. Recovery decisions wait for `relaunchObserved` with authoritative task facts.
    public static func structural(
        from status: DownloadStatus,
        admissionPending: Bool,
        finalizingEvidence: Bool
    ) -> DownloadLifecycle {
        switch status {
        case .queued: return .admitted
        case .preparing: return .serverPrep
        case .downloading: return finalizingEvidence ? .finalizing : .transferring
        case .complete: return .complete
        case .unverified: return .unverified
        case .paused: return .paused
        case .failed: return admissionPending ? .planned : .failed
        }
    }
}

/// Why a row is paused. Resume destinations come from facts, not from this cause; the cause
/// decides whether an automatic resume is allowed and what the row says.
public enum DownloadPauseCause: String, Codable, Sendable {
    case user
    case queuePaused
    case systemInterrupted
    case awaitingSession
    case storage
    case deferredResume
}

/// Bounded failure categories (never free-form server text).
public enum DownloadFailureReason: String, Codable, Sendable {
    case storage
    case auth
    case network
    case server
    case validation
    case sourceMissing
    case cancelledBySystem
    case aborted
    case stalled
    case internalError
}

public enum DownloadUnverifiedReason: Codable, Sendable, Equatable {
    case probeMiss(String)
    case truncatedRepeated
    case backgroundProbeDeferred
    case migratedUnknown

    private enum CodingKeys: String, CodingKey { case kind, detail }
    private enum Kind: String, Codable { case probeMiss, truncatedRepeated, backgroundProbeDeferred, migratedUnknown }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .probeMiss: self = .probeMiss(try c.decodeIfPresent(String.self, forKey: .detail) ?? "")
        case .truncatedRepeated: self = .truncatedRepeated
        case .backgroundProbeDeferred: self = .backgroundProbeDeferred
        case .migratedUnknown: self = .migratedUnknown
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .probeMiss(let detail):
            try c.encode(Kind.probeMiss, forKey: .kind)
            try c.encode(detail, forKey: .detail)
        case .truncatedRepeated: try c.encode(Kind.truncatedRepeated, forKey: .kind)
        case .backgroundProbeDeferred: try c.encode(Kind.backgroundProbeDeferred, forKey: .kind)
        case .migratedUnknown: try c.encode(Kind.migratedUnknown, forKey: .kind)
        }
    }
}

public enum DownloadAdmissionIntent: String, Codable, Sendable {
    /// A season-planner row waiting for its lane (today: `seasonPlannerPendingAdmission`).
    case seasonPlanned
    case retryRequested
}

/// What a truncation strike was counted against. Components that are not yet known (a part that
/// is still being negotiated) are nil; only a proven difference resets strikes (R2-5).
public struct DownloadSourceKey: Codable, Sendable, Equatable {
    public var server: String?
    public var account: String?
    public var backend: String?
    public var item: String
    public var source: String?
    public var profile: String?

    public init(server: String?, account: String?, backend: String?, item: String,
                source: String?, profile: String?) {
        self.server = server
        self.account = account
        self.backend = backend
        self.item = item
        self.source = source
        self.profile = profile
    }

    /// True only when a component is known on both sides and differs.
    public func provenDifferent(from other: DownloadSourceKey) -> Bool {
        func differs(_ a: String?, _ b: String?) -> Bool {
            guard let a, let b else { return false }
            return a != b
        }
        return item != other.item || differs(server, other.server)
            || differs(account, other.account) || differs(backend, other.backend)
            || differs(source, other.source) || differs(profile, other.profile)
    }
}

public struct DownloadTruncationHistory: Codable, Sendable, Equatable {
    public var strikes: Int
    public var sourceKey: DownloadSourceKey
    /// Recent finalize outcome IDs already counted; a replayed outcome is a no-op. Bounded.
    public var countedOutcomeIDs: [String]

    public static let rememberedOutcomeLimit = 8

    public init(strikes: Int, sourceKey: DownloadSourceKey, countedOutcomeIDs: [String] = []) {
        self.strikes = strikes
        self.sourceKey = sourceKey
        self.countedOutcomeIDs = countedOutcomeIDs
    }
}

public struct DownloadStoragePark: Codable, Sendable, Equatable {
    public var requiredBytes: Int64?
    public var measuredAtEpochSeconds: Double

    public init(requiredBytes: Int64?, measuredAtEpochSeconds: Double) {
        self.requiredBytes = requiredBytes
        self.measuredAtEpochSeconds = measuredAtEpochSeconds
    }
}

/// Facts the reducer appends to and reads; persisted with the row (P3a).
public struct DownloadAttemptHistory: Codable, Sendable, Equatable {
    public var truncation: DownloadTruncationHistory?
    public var unverifiedReason: DownloadUnverifiedReason?
    public var lastFailure: DownloadFailureReason?
    public var storagePark: DownloadStoragePark?
    public var pauseCause: DownloadPauseCause?
    public var admissionIntent: DownloadAdmissionIntent?

    public init(truncation: DownloadTruncationHistory? = nil,
                unverifiedReason: DownloadUnverifiedReason? = nil,
                lastFailure: DownloadFailureReason? = nil,
                storagePark: DownloadStoragePark? = nil,
                pauseCause: DownloadPauseCause? = nil,
                admissionIntent: DownloadAdmissionIntent? = nil) {
        self.truncation = truncation
        self.unverifiedReason = unverifiedReason
        self.lastFailure = lastFailure
        self.storagePark = storagePark
        self.pauseCause = pauseCause
        self.admissionIntent = admissionIntent
    }

    public static let empty = DownloadAttemptHistory()

    /// Count one truncation outcome (R2-5): replayed IDs are ignored, a proven source change
    /// restarts the count. Returns the updated history and whether this outcome was new.
    public func recordingTruncation(
        outcomeID: String, source: DownloadSourceKey
    ) -> (history: DownloadAttemptHistory, recorded: Bool) {
        var next = self
        var truncation = next.truncation
        if truncation?.countedOutcomeIDs.contains(outcomeID) == true { return (self, false) }
        if truncation == nil || truncation!.sourceKey.provenDifferent(from: source) {
            truncation = DownloadTruncationHistory(strikes: 0, sourceKey: source)
        }
        truncation!.strikes += 1
        truncation!.countedOutcomeIDs = Array(
            (truncation!.countedOutcomeIDs + [outcomeID])
                .suffix(DownloadTruncationHistory.rememberedOutcomeLimit))
        next.truncation = truncation
        return (next, true)
    }

    /// History a replacement attempt inherits (R2-5): truncation strikes for the same source, and
    /// nothing else. Everything else describes the previous attempt only.
    public func inherited(by newSource: DownloadSourceKey) -> DownloadAttemptHistory {
        guard let truncation, !truncation.sourceKey.provenDifferent(from: newSource) else {
            return .empty
        }
        return DownloadAttemptHistory(truncation: truncation)
    }
}
