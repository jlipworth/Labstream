import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Status of an Emby "Convert Media" Sync job (`GET /Sync/Jobs/{id}` → `Status`).
///
/// The observed server strings (Emby 4.9.3) are `Queued` → `Converting`/`Transferring` →
/// `Completed` / `Failed` / `Cancelled`. Emby's `SyncJobStatus` also defines `ReadyToTransfer` and
/// `CompletedWithError`, which have not been observed live on the Convert lane (B48):
/// - `ReadyToTransfer` sits between conversion and the transfer step, so it is modelled as
///   NON-terminal (keep polling until `Completed`).
/// - `CompletedWithError` means the job ended but its item failed. It is modelled as a TERMINAL
///   FAILURE. Decoding it to `.unknown` kept the job non-terminal, and every healthy 200 reset the
///   poll budget, so the row polled forever. As a failure it clears the job id, so Retry creates a
///   fresh job (and the reuse preflight still adopts any file the server did produce).
/// Both assumptions come from the server enum, not from a live capture, and still need live
/// verification against a server that emits them.
///
/// An unrecognized/absent string decodes to `.unknown` rather than throwing, so a
/// forward-incompatible server value never crashes polling — it is simply treated as non-terminal
/// (keep polling).
public enum EmbyConvertJobStatus: String, Decodable, Sendable, Equatable {
    case queued = "Queued"
    case converting = "Converting"
    case readyToTransfer = "ReadyToTransfer"
    case transferring = "Transferring"
    case completed = "Completed"
    case completedWithError = "CompletedWithError"
    case failed = "Failed"
    case cancelled = "Cancelled"
    /// Any server string we don't recognize (forward-compat). Never terminal.
    case unknown

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = EmbyConvertJobStatus(rawValue: raw) ?? .unknown
    }

    /// True once the job has reached a final state (success OR failure/cancel) — stop polling.
    public var isTerminal: Bool {
        switch self {
        case .completed, .completedWithError, .failed, .cancelled:
            return true
        case .queued, .converting, .readyToTransfer, .transferring, .unknown:
            return false
        }
    }

    /// True only when the job finished and produced the converted file.
    public var didSucceed: Bool {
        self == .completed
    }

    /// User-facing phrase for a terminal failure ("Server conversion <phrase>."). Nil for
    /// non-terminal and successful statuses.
    public var terminalFailureDescription: String? {
        switch self {
        case .failed: return "failed"
        case .cancelled: return "was cancelled"
        case .completedWithError: return "finished with an error"
        case .queued, .converting, .readyToTransfer, .transferring, .completed, .unknown:
            return nil
        }
    }
}

/// A single Emby Convert-Media Sync job (`POST /Sync/Jobs` result / `GET /Sync/Jobs/{id}`).
///
/// `progress` is a 0–100 percentage (`null` until the job starts converting). All fixtures /
/// callers use placeholder ids (repo goes public).
public struct EmbyConvertJob: Decodable, Sendable, Equatable {
    public let id: Int
    public let status: EmbyConvertJobStatus
    public let progress: Double?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case status = "Status"
        case progress = "Progress"
    }

    public init(id: Int, status: EmbyConvertJobStatus, progress: Double?) {
        self.id = id
        self.status = status
        self.progress = progress
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        status = try c.decodeIfPresent(EmbyConvertJobStatus.self, forKey: .status) ?? .unknown
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
    }
}

/// Identity-bearing row returned by `GET /Sync/Jobs`.
///
/// Emby serializes item/user identifiers as JSON numbers on current servers even though the
/// corresponding request APIs accept strings. Recovery normalizes the requested item ids to
/// strings so callers never have to guess which wire representation a server version uses.
public struct EmbyConvertRecoveryEntry: Decodable, Sendable, Equatable {
    public let id: Int
    public let requestedItemIds: [String]
    public let itemId: String?
    public let targetId: String
    public let quality: String
    public let profile: String
    public let bitrate: Int?
    public let status: EmbyConvertJobStatus
    public let progress: Double?
    public let dateCreated: String?
    public let dateLastModified: String?
    public let userId: String?
    public let syncNewContent: Bool?
    public let unwatchedOnly: Bool?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case requestedItemIds = "RequestedItemIds"
        case itemId = "ItemId"
        case targetId = "TargetId"
        case quality = "Quality"
        case profile = "Profile"
        case bitrate = "Bitrate"
        case status = "Status"
        case progress = "Progress"
        case dateCreated = "DateCreated"
        case dateLastModified = "DateLastModified"
        case userId = "UserId"
        case syncNewContent = "SyncNewContent"
        case unwatchedOnly = "UnwatchedOnly"
    }

    public init(id: Int, requestedItemIds: [String], itemId: String? = nil,
                targetId: String, quality: String, profile: String, bitrate: Int?,
                status: EmbyConvertJobStatus = .unknown, progress: Double? = nil,
                dateCreated: String? = nil, dateLastModified: String? = nil,
                userId: String? = nil, syncNewContent: Bool? = nil, unwatchedOnly: Bool? = nil) {
        self.id = id
        self.requestedItemIds = requestedItemIds
        self.itemId = itemId
        self.targetId = targetId
        self.quality = quality
        self.profile = profile
        self.bitrate = bitrate
        self.status = status
        self.progress = progress
        self.dateCreated = dateCreated
        self.dateLastModified = dateLastModified
        self.userId = userId
        self.syncNewContent = syncNewContent
        self.unwatchedOnly = unwatchedOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        if let values = try? c.decode([String].self, forKey: .requestedItemIds) {
            requestedItemIds = values
        } else {
            requestedItemIds = (try? c.decode([Int].self, forKey: .requestedItemIds))?.map(String.init) ?? []
        }
        if let value = try? c.decode(String.self, forKey: .itemId) {
            itemId = value
        } else {
            itemId = (try? c.decode(Int.self, forKey: .itemId)).map(String.init)
        }
        // `GET /Sync/Jobs` is server-wide: it also returns jobs created by OTHER clients (Emby
        // mobile sync, etc.), which may omit/null these fields or use the numeric wire variant.
        // Decode them tolerantly to an empty string — a foreign job must never make the whole
        // baseline/recovery list undecodable (that failed EVERY convert start). An empty value can
        // never equal a Labstream fingerprint's non-empty quality/profile, so matching stays exact.
        if let value = try? c.decode(String.self, forKey: .targetId) {
            targetId = value
        } else {
            targetId = (try? c.decode(Int.self, forKey: .targetId)).map(String.init) ?? ""
        }
        quality = (try? c.decode(String.self, forKey: .quality)) ?? ""
        profile = (try? c.decode(String.self, forKey: .profile)) ?? ""
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        status = try c.decodeIfPresent(EmbyConvertJobStatus.self, forKey: .status) ?? .unknown
        progress = try c.decodeIfPresent(Double.self, forKey: .progress)
        dateCreated = try c.decodeIfPresent(String.self, forKey: .dateCreated)
        dateLastModified = try c.decodeIfPresent(String.self, forKey: .dateLastModified)
        if let value = try? c.decode(String.self, forKey: .userId) {
            userId = value
        } else {
            userId = (try? c.decode(Int.self, forKey: .userId)).map(String.init)
        }
        syncNewContent = try c.decodeIfPresent(Bool.self, forKey: .syncNewContent)
        unwatchedOnly = try c.decodeIfPresent(Bool.self, forKey: .unwatchedOnly)
    }
}

/// Envelope returned by the list endpoint. The server does not guarantee creation-time ordering.
public struct EmbyConvertJobList: Decodable, Sendable, Equatable {
    public let items: [EmbyConvertRecoveryEntry]
    public let totalRecordCount: Int
    /// Entries in the wire payload that could not be decoded even tolerantly (foreign clients'
    /// jobs with unexpected shapes). They are dropped from `items` but still counted so a foreign
    /// job never masquerades as a truncated page.
    public let undecodableItemCount: Int

    /// Recovery requires the complete server baseline, never a silently truncated page. A dropped
    /// foreign entry was still RECEIVED, so it counts toward completeness — it can never match a
    /// Labstream fingerprint anyway.
    public var isComplete: Bool { totalRecordCount == items.count + undecodableItemCount }

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }

    /// Consumes one unkeyed-container slot without asserting anything about its shape, so a
    /// per-entry decode failure can skip that entry instead of failing the whole list.
    private struct SkippedEntry: Decodable {
        init(from decoder: Decoder) throws {}
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalRecordCount = try c.decode(Int.self, forKey: .totalRecordCount)
        var entries = try c.nestedUnkeyedContainer(forKey: .items)
        var decoded: [EmbyConvertRecoveryEntry] = []
        var dropped = 0
        while !entries.isAtEnd {
            if let entry = try? entries.decode(EmbyConvertRecoveryEntry.self) {
                decoded.append(entry)
            } else {
                _ = try entries.decode(SkippedEntry.self)
                dropped += 1
            }
        }
        items = decoded
        undecodableItemCount = dropped
    }
}

/// Pure fail-closed recovery for the POST-response persistence crash window.
public enum EmbyConvertRecoveryPolicy {
    public static let candidateClockSkewSeconds: TimeInterval = 5
    public static let maximumCreateResponseWindowSeconds: TimeInterval = 10 * 60
    public static let recoveryExpirySeconds: TimeInterval = 24 * 60 * 60

    public enum Phase: String, Codable, Sendable, Equatable {
        case prepared
        case dispatchAmbiguous
    }
    public enum CreateFailureDisposition: Sendable, Equatable {
        case clearRecovery
        case preserveForRecovery
    }
    public enum CleanupAction: Sendable, Equatable {
        case cancel(jobID: Int)
        case retainTombstone
        case discardTombstone
    }
    public enum RelaunchAction: Sendable, Equatable {
        case poll(jobID: Int)
        case recover(baselineJobIDs: [Int], fingerprint: Fingerprint,
                     attemptStartedAtEpochSeconds: Double, phase: Phase)
        case failMissingIdentity
        /// The crash-window identity is older than `recoveryExpirySeconds`: `matchingNewJobIDs`
        /// can never adopt again, so recovery must hand the identity to cleanup and release the
        /// row for a fresh attempt instead of looping `.preparing` → `.failed` forever.
        case expireRecovery
    }

    public struct Fingerprint: Codable, Sendable, Equatable {
        public let itemId: String
        public let targetId: String
        public let quality: String
        public let profile: String
        public let bitrate: Int?
        public let userId: String?
        public let syncNewContent: Bool
        public let unwatchedOnly: Bool
        // Emby 4.9.3's list response does not expose these create shapers, but they remain durably
        // recorded so a future server field can tighten matching without a metadata migration.
        public let container: String?
        public let videoCodec: String?
        public let audioCodec: String?
        public let audioStreamIndex: Int?

        public init(itemId: String, targetId: String = "originalmediafolder",
                    quality: String, profile: String, bitrate: Int?, userId: String? = nil,
                    syncNewContent: Bool = false, unwatchedOnly: Bool = false,
                    container: String? = nil, videoCodec: String? = nil,
                    audioCodec: String? = nil, audioStreamIndex: Int? = nil) {
            self.itemId = itemId
            self.targetId = targetId
            self.quality = quality
            self.profile = profile
            self.bitrate = bitrate
            self.userId = userId
            self.syncNewContent = syncNewContent
            self.unwatchedOnly = unwatchedOnly
            self.container = container
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
            self.audioStreamIndex = audioStreamIndex
        }
    }

    /// Returns a job id only when the full-baseline difference contains exactly one exact match.
    /// Zero or multiple matches are deliberately indistinguishable and remain fail-closed.
    public static func recoveredJobID(baselineJobIDs: Set<Int>,
                                      jobs: [EmbyConvertRecoveryEntry],
                                      fingerprint: Fingerprint,
                                      attemptStartedAtEpochSeconds: Double? = nil,
                                      phase: Phase = .dispatchAmbiguous,
                                      nowEpochSeconds: Double = Date().timeIntervalSince1970) -> Int? {
        let matches = matchingNewJobIDs(
            baselineJobIDs: baselineJobIDs, jobs: jobs, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: attemptStartedAtEpochSeconds,
            phase: phase, nowEpochSeconds: nowEpochSeconds)
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    public static func matchingNewJobIDs(baselineJobIDs: Set<Int>,
                                         jobs: [EmbyConvertRecoveryEntry],
                                         fingerprint: Fingerprint,
                                         attemptStartedAtEpochSeconds: Double? = nil,
                                         phase: Phase = .dispatchAmbiguous,
                                         nowEpochSeconds: Double = Date().timeIntervalSince1970) -> [Int] {
        guard phase == .dispatchAmbiguous else { return [] }
        if let start = attemptStartedAtEpochSeconds,
           nowEpochSeconds > start + recoveryExpirySeconds { return [] }
        return jobs.filter {
            !baselineJobIDs.contains($0.id)
                && $0.requestedItemIds.contains(fingerprint.itemId)
                && $0.targetId == fingerprint.targetId
                && $0.quality == fingerprint.quality
                && $0.profile == fingerprint.profile
                && $0.bitrate == fingerprint.bitrate
                // Emby 4.9.3 returns `UserId` here as an internal JSON integer, while create takes
                // the public user GUID/string and exposes no mapping endpoint between them. Persist
                // the requested id in the fingerprint, but do not pretend these unequal id domains
                // are comparable (live mutation proved every other exposed field matched).
                && $0.syncNewContent == fingerprint.syncNewContent
                && $0.unwatchedOnly == fingerprint.unwatchedOnly
                && candidateDateIsBounded($0.dateCreated,
                                          attemptStartedAtEpochSeconds: attemptStartedAtEpochSeconds)
        }.map(\.id).sorted()
    }

    private static func candidateDateIsBounded(_ raw: String?,
                                               attemptStartedAtEpochSeconds: Double?) -> Bool {
        guard let start = attemptStartedAtEpochSeconds else { return true }
        guard let raw else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let epoch = date?.timeIntervalSince1970 else { return false }
        return epoch >= start - candidateClockSkewSeconds
            && epoch <= start + maximumCreateResponseWindowSeconds
    }

    /// Durable crash-window recovery identity of a live row: enough to recompute which server job
    /// that row would adopt.
    public struct LiveRecoveryIdentity: Equatable, Sendable {
        public let baselineJobIDs: Set<Int>
        public let fingerprint: Fingerprint
        public let attemptStartedAtEpochSeconds: Double
        public let phase: Phase

        public init(baselineJobIDs: Set<Int>, fingerprint: Fingerprint,
                    attemptStartedAtEpochSeconds: Double, phase: Phase) {
            self.baselineJobIDs = baselineJobIDs
            self.fingerprint = fingerprint
            self.attemptStartedAtEpochSeconds = attemptStartedAtEpochSeconds
            self.phase = phase
        }
    }

    /// B49: every job a live row owns, either by persisted id or because its crash-window recovery
    /// would adopt it. Cleanup must never cancel these, even before recovery persists the id.
    public static func claimedJobIDs(liveJobIDs: Set<Int>,
                                     liveRecoveryIdentities: [LiveRecoveryIdentity],
                                     jobs: [EmbyConvertRecoveryEntry],
                                     nowEpochSeconds: Double) -> Set<Int> {
        var claimed = liveJobIDs
        for identity in liveRecoveryIdentities {
            claimed.formUnion(matchingNewJobIDs(
                baselineJobIDs: identity.baselineJobIDs, jobs: jobs,
                fingerprint: identity.fingerprint,
                attemptStartedAtEpochSeconds: identity.attemptStartedAtEpochSeconds,
                phase: identity.phase, nowEpochSeconds: nowEpochSeconds))
        }
        return claimed
    }

    public static func cleanupAction(baselineJobIDs: Set<Int>,
                                     jobs: [EmbyConvertRecoveryEntry],
                                     listIsComplete: Bool,
                                     fingerprint: Fingerprint,
                                     attemptStartedAtEpochSeconds: Double,
                                     phase: Phase,
                                     nowEpochSeconds: Double,
                                     liveJobIDs: Set<Int> = []) -> CleanupAction {
        guard phase == .dispatchAmbiguous else { return .discardTombstone }
        guard listIsComplete else { return .retainTombstone }
        // Cleanup may still cancel a uniquely identified long-retained job after the recovery
        // adoption deadline. Evaluate its creation window just before expiry, then use expiry only
        // to decide when a complete zero-candidate result proves there is nothing left to clean.
        //
        // `liveJobIDs` are jobs currently OWNED by live download rows. A tombstone must never
        // cancel one: re-downloading the same item/preset shortly after a crash-window delete
        // creates a new job whose fingerprint and creation window match the tombstone's, and
        // without this exclusion the sweep would DELETE the user's active conversion.
        let matching = matchingNewJobIDs(
            baselineJobIDs: baselineJobIDs, jobs: jobs, fingerprint: fingerprint,
            attemptStartedAtEpochSeconds: attemptStartedAtEpochSeconds, phase: phase,
            nowEpochSeconds: min(nowEpochSeconds,
                                 attemptStartedAtEpochSeconds + recoveryExpirySeconds - 1))
            .filter { !liveJobIDs.contains($0) }
        if matching.count == 1, let id = matching.first { return .cancel(jobID: id) }
        if matching.isEmpty,
           nowEpochSeconds > attemptStartedAtEpochSeconds + recoveryExpirySeconds {
            return .discardTombstone
        }
        return .retainTombstone
    }

    /// Pure manager boundary: a persisted job id always wins; otherwise recovery requires both
    /// halves of the durable pre-POST identity. Partial/legacy state remains fail-closed.
    ///
    /// Identity older than `recoveryExpirySeconds` returns `.expireRecovery` instead of
    /// `.recover`: `matchingNewJobIDs` hard-returns `[]` past expiry, so re-entering recovery
    /// could only ever fail again — the row would loop `.preparing` → `.failed` on every Retry
    /// with delete as the user's only escape. Cleanup tombstones carry the same expiry escape.
    public static func relaunchAction(jobID: Int?, baselineJobIDs: [Int]?,
                                      fingerprint: Fingerprint?,
                                      attemptStartedAtEpochSeconds: Double? = nil,
                                      phase: Phase? = nil,
                                      nowEpochSeconds: Double = Date().timeIntervalSince1970) -> RelaunchAction {
        if let jobID { return .poll(jobID: jobID) }
        if let baselineJobIDs, let fingerprint, let attemptStartedAtEpochSeconds,
           let phase, phase == .dispatchAmbiguous {
            if nowEpochSeconds > attemptStartedAtEpochSeconds + recoveryExpirySeconds {
                return .expireRecovery
            }
            return .recover(baselineJobIDs: baselineJobIDs, fingerprint: fingerprint,
                            attemptStartedAtEpochSeconds: attemptStartedAtEpochSeconds, phase: phase)
        }
        return .failMissingIdentity
    }

    /// Once POST is dispatched, a transport failure or unusable 2xx body cannot prove the server
    /// did not create the job. Only pre-dispatch failures and explicit 4xx rejections may discard
    /// the baseline safely; 5xx responses remain commit-ambiguous.
    public static func createFailureDisposition(postWasDispatched: Bool,
                                                httpStatusCode: Int?) -> CreateFailureDisposition {
        guard postWasDispatched else { return .clearRecovery }
        if let httpStatusCode, (400..<500).contains(httpStatusCode) { return .clearRecovery }
        return .preserveForRecovery
    }

    /// What a convert chain does with the job its create POST returned once that chain is no longer
    /// the current attempt (B47).
    public enum StaleCreateDisposition: Equatable, Sendable {
        /// The row this attempt created is still there but parked (paused/failed) with no job id:
        /// persist the job id onto it, keep it parked, so Resume polls that exact job.
        case adoptOntoParkedRow
        /// The row is owned and either already holds this job, or a newer server-prep chain (e.g.
        /// pause → resume re-entering crash-window recovery) owns the dispatch evidence and will
        /// adopt the job itself. Do nothing, so neither chain cancels or races the other.
        case leaveToCurrentOwner
        /// Nothing owns the job (row deleted or replaced, or it holds a different job): cancel it.
        case cancel
    }

    /// Decide the post-create disposition for a stale convert chain. `rowOwnedByAttempt` is true
    /// when the store row still belongs to the exact attempt that dispatched POST, is not pending
    /// deletion, and still carries this preset. Pausing during POST used to cancel the new job while
    /// the paused row kept its dispatchAmbiguous identity, so Resume found zero matches and failed.
    public static func staleCreateDisposition(rowOwnedByAttempt: Bool,
                                              rowStatus: DownloadStatus?,
                                              persistedJobID: Int?,
                                              createdJobID: Int) -> StaleCreateDisposition {
        guard rowOwnedByAttempt, let rowStatus else { return .cancel }
        if let persistedJobID {
            return persistedJobID == createdJobID ? .leaveToCurrentOwner : .cancel
        }
        switch rowStatus {
        case .paused, .failed:
            return .adoptOntoParkedRow
        case .preparing:
            return .leaveToCurrentOwner
        case .queued, .downloading, .complete, .unverified:
            return .cancel
        }
    }

    /// Recovery/cancellation must run under the same public Emby user that created the job. The
    /// Sync-list `UserId` is an incomparable internal integer, so ownership is enforced against the
    /// two public ids we control and persist locally instead.
    ///
    /// Equality is GUID-format-insensitive (`MediaBrowserUserIdentity.sameUser`), the same rule
    /// `BackendSession.matchesPersistedServer` applies (B52): Emby may reformat the same user GUID
    /// across re-logins, and a raw compare would skip recovery and cleanup forever.
    public static func publicUserMatches(currentSessionUserID: String?,
                                         persistedBackendUserID: String?,
                                         fingerprintUserID: String?) -> Bool {
        let values = [currentSessionUserID, persistedBackendUserID, fingerprintUserID].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard values.count == 3 else { return false }
        return MediaBrowserUserIdentity.sameUser(values[0], values[1])
            && MediaBrowserUserIdentity.sameUser(values[1], values[2])
    }

}

/// Pure request builders + response models for the Emby "Convert Media" Sync job lane (the
/// server-side prepare-then-download path). Mirrors the existing `EmbyPlayback` request style:
/// auth via `EmbyAuth.applyAuth`, base-path-preserving URL join via `EmbyPlayback.embyURL`.
///
/// Verified live (Emby 4.9.3): `POST /Sync/Jobs` body keys are **lowercase camelCase**
/// (PascalCase returns HTTP 500); `targetId:"originalmediafolder"` = persistent "next to
/// original files" (NEVER `originalmediafolderreplace`, which is destructive).
public enum EmbyConvertRequest {
    /// Picker-preset → Emby convert (`quality`, `profile`, `bitrate`) mapping.
    ///
    /// The `originalmediafolder` target rejects the literal `quality:"original"` token (HTTP 500),
    /// so "Original video quality" maps to a high keep-quality bitrate (`keepQualityBitrate`) with
    /// `profile:"tv"` — NOT `"original"`. Bitrate presets map to `quality:"custom"` +
    /// `bitrate:<bps>` + `profile:"tv"`. Live-verified (Emby 4.9.3): the target honors arbitrary
    /// custom bitrates (40 Mbps accepted + actively transcoding), so there is NO 8 Mbps cap.
    public struct ConvertQuality: Sendable, Equatable {
        public let quality: String
        public let profile: String
        public let bitrate: Int?
        /// Custom-profile target criteria (#128). Non-nil ONLY for `profile:"custom"`: Emby's
        /// "Convert → Custom" path REQUIRES `Container`/`VideoCodec`/`AudioCodec` (a bare custom job is
        /// rejected HTTP 400) and, unlike `tv`, applies no 1080p downscale — so this is the true-4K lane.
        public let container: String?
        public let videoCodec: String?
        public let audioCodec: String?

        public init(quality: String, profile: String, bitrate: Int?,
                    container: String? = nil, videoCodec: String? = nil, audioCodec: String? = nil) {
            self.quality = quality
            self.profile = profile
            self.bitrate = bitrate
            self.container = container
            self.videoCodec = videoCodec
            self.audioCodec = audioCodec
        }
    }

    /// True-4K custom-profile criteria (#128). h264/mp4/aac: the convert lane only ever runs for
    /// sources that CAN'T direct-play, so a universally playable target codec is the safe pick.
    /// `profile:"custom"` preserves the source resolution (no `tv` downscale) → genuine 4K output.
    /// The codec/container triple is REQUIRED — Emby rejects a bare custom job with HTTP 400.
    public static func customFourKQuality(bitrate: Int) -> ConvertQuality {
        ConvertQuality(quality: "custom", profile: "custom", bitrate: bitrate,
                       container: "mp4", videoCodec: "h264", audioCodec: "aac")
    }

    /// Keep-quality stand-in bitrate for "Original video quality". The `originalmediafolder` target
    /// rejects the literal `quality:"original"` token (HTTP 500), so we send a high custom bitrate
    /// that preserves quality instead. Live-verified that arbitrary high bitrates are honored.
    public static let keepQualityBitrate = 80_000_000

    /// Map a download-picker preset label to an Emby convert `(quality, profile, bitrate[, criteria])`.
    ///
    /// Resolution-preserving presets route through `profile:"custom"` (the true-4K lane, #128); the
    /// rest keep `profile:"tv"` (whose 1080p ceiling is exactly what a sub-1080p preset wants):
    /// - "Original video quality" → `profile:"custom"` + mp4/h264/aac at `keepQualityBitrate` (80 Mbps).
    ///   Preserves the source resolution; `tv` would silently downscale a 4K "Original" to 1080p.
    /// - A 4K/2160 preset (e.g. "4K 40 Mbps") → `profile:"custom"` + mp4/h264/aac at its labelled bps.
    /// - A 1080p/720p/480p preset → `quality:"custom"`, `bitrate:<bps>`, `profile:"tv"` (the `tv`
    ///   ceiling delivers the requested downscale; no cap on bitrate — Emby honors it).
    /// - Unrecognized label → keep-quality fallback via the resolution-preserving custom path.
    public static func convertQuality(forPresetLabel label: String) -> ConvertQuality {
        let normalized = label.lowercased()

        // "Original video quality" — preserve the source resolution via custom (tv downscales 4K→1080p).
        if normalized.contains("original") {
            return customFourKQuality(bitrate: keepQualityBitrate)
        }

        if let bps = bitrate(forPresetLabel: normalized) {
            // 4K / 2160p presets need custom to escape the tv profile's 1080p ceiling (#128); the
            // lower tiers explicitly want a downscale, which tv already provides.
            if normalized.contains("4k") || normalized.contains("2160") {
                return customFourKQuality(bitrate: bps)
            }
            return ConvertQuality(quality: "custom", profile: "tv", bitrate: bps)
        }

        // Unknown preset → keep-quality fallback (resolution-preserving custom path).
        return customFourKQuality(bitrate: keepQualityBitrate)
    }

    /// Extract a bits-per-second value from a picker preset label (e.g. "4K · 40 Mbps" → 40_000_000,
    /// "1080p · 8 Mbps" → 8_000_000, "480p · 1.5 Mbps" → 1_500_000). NOT capped: the
    /// `originalmediafolder` target honors arbitrary custom bitrates (live-verified). Returns nil
    /// when no "<n> Mbps" token is present.
    static func bitrate(forPresetLabel normalizedLabel: String) -> Int? {
        // Find a "<number> mbps" token; the number may be fractional (e.g. 1.5).
        guard let mbpsRange = normalizedLabel.range(of: "mbps") else { return nil }

        // Pull the last numeric run that precedes "mbps".
        var lastNumber: Double?
        let prefix = String(normalizedLabel[..<mbpsRange.lowerBound])
        var current = ""
        for ch in prefix {
            if ch.isNumber || ch == "." {
                current.append(ch)
            } else if !current.isEmpty {
                lastNumber = Double(current) ?? lastNumber
                current = ""
            }
        }
        if !current.isEmpty { lastNumber = Double(current) ?? lastNumber }

        guard let mbps = lastNumber, mbps > 0 else { return nil }
        return Int((mbps * 1_000_000).rounded())
    }

    /// `POST {server}/Sync/Jobs` — create an Emby "Convert Media" job for `itemId` targeting
    /// `originalmediafolder` (persistent "next to original files"). Body is **lowercase camelCase**
    /// (the existing convention; live-verified that camelCase keys bind). Standard Emby auth via
    /// `EmbyAuth.applyAuth`.
    ///
    /// `container`/`videoCodec`/`audioCodec` are the `profile:"custom"` target criteria (#128) and
    /// MUST be supplied together for a custom job (Emby rejects a bare custom job HTTP 400); they are
    /// omitted entirely for the `tv`/`mobile` profiles, which carry their own built-in targets.
    /// `audioStreamIndex` is best-effort download-track steering for single-audio converted outputs.
    /// It follows Emby's lowercase-camel Sync job body convention used by the rest of this request.
    public static func createJobRequest(server: URL,
                                        token: String,
                                        identity: EmbyClientIdentity,
                                        userId: String,
                                        itemId: String,
                                        quality: String,
                                        profile: String,
                                        bitrate: Int?,
                                        name: String,
                                        container: String? = nil,
                                        videoCodec: String? = nil,
                                        audioCodec: String? = nil,
                                        audioStreamIndex: Int? = nil) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Sync/Jobs")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: userId, token: token)

        var body: [String: Any] = [
            "userId": userId,
            "itemIds": [itemId],
            "category": NSNull(),
            "parentId": NSNull(),
            "targetId": "originalmediafolder",
            "quality": quality,
            "profile": profile,
            "bitrate": bitrate.map { $0 as Any } ?? NSNull(),
            "name": name,
            "unwatchedOnly": false,
            "syncNewContent": false,
            "itemLimit": NSNull(),
        ]
        // Custom-profile criteria (#128) — only present for the true-4K path.
        if let container { body["container"] = container }
        if let videoCodec { body["videoCodec"] = videoCodec }
        if let audioCodec { body["audioCodec"] = audioCodec }
        if let audioStreamIndex, audioStreamIndex >= 0 { body["audioStreamIndex"] = audioStreamIndex }
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    /// `GET {server}/Sync/Jobs/{jobId}` — poll a convert job's `Status`/`Progress`.
    public static func jobStatusRequest(server: URL,
                                        token: String,
                                        identity: EmbyClientIdentity,
                                        jobId: Int) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Sync/Jobs/\(jobId)")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: nil, token: token)
        return req
    }

    /// `GET {server}/Sync/Jobs` — list the complete Sync-job baseline used by fail-closed recovery.
    public static func jobListRequest(server: URL,
                                      token: String,
                                      identity: EmbyClientIdentity) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Sync/Jobs")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: nil, token: token)
        return req
    }

    /// `DELETE {server}/Sync/Jobs/{jobId}` — cancel a job the user abandons. Deleting the job does
    /// NOT delete the already-converted file (verified live), so this only ever cancels an
    /// in-flight conversion; never call it on success.
    public static func deleteJobRequest(server: URL,
                                        token: String,
                                        identity: EmbyClientIdentity,
                                        jobId: Int) throws -> URLRequest {
        let url = try EmbyPlayback.embyURL(server: server, path: "/Sync/Jobs/\(jobId)")
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: nil, token: token)
        return req
    }

    /// `POST {server}/Items/{itemId}/Refresh` — ask Emby to rescan/re-index one item after a
    /// convert job copied a persistent file next to the original. Emby can finish the Sync job and
    /// place the MP4 on disk before PlaybackInfo exposes it as a second `File` MediaSource; a
    /// targeted refresh is the same shape the web client uses and returns HTTP 204 on success.
    public static func itemRefreshRequest(server: URL,
                                          token: String,
                                          identity: EmbyClientIdentity,
                                          userId: String,
                                          itemId: String) throws -> URLRequest {
        var comps = URLComponents(url: try EmbyPlayback.embyURL(server: server, path: "/Items/\(itemId)/Refresh"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "MetadataRefreshMode", value: "Default"),
            URLQueryItem(name: "ImageRefreshMode", value: "Default"),
            URLQueryItem(name: "ReplaceAllMetadata", value: "false"),
            URLQueryItem(name: "ReplaceAllImages", value: "false"),
        ]
        guard let url = comps.url else { throw EmbyPlaybackError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        EmbyAuth.applyAuth(to: &req, identity: identity, userId: userId, token: token)
        return req
    }

    /// Decode a `GET /Sync/Jobs/{id}` (single-job poll) response body into an `EmbyConvertJob`.
    ///
    /// The single-job GET returns the job at the TOP LEVEL (`{ "Id", "Status", "Progress", … }`),
    /// so `EmbyConvertJob` decodes it directly. The `POST /Sync/Jobs` CREATE response is a different
    /// shape — use `decodeCreatedJob(from:)` for that.
    public static func decodeJob(from data: Data) throws -> EmbyConvertJob {
        try JSONDecoder().decode(EmbyConvertJob.self, from: data)
    }

    public static func decodeJobList(from data: Data) throws -> EmbyConvertJobList {
        try JSONDecoder().decode(EmbyConvertJobList.self, from: data)
    }

    /// Decode a `POST /Sync/Jobs` (create) response body into the created `EmbyConvertJob`.
    ///
    /// Verified live (Emby 4.9.3): unlike the single-job GET, the create response is a
    /// `SyncJobCreationResult` envelope that NESTS the job under `"Job"`:
    /// `{ "Job": { "Id", "Status", "Progress", … }, "JobItems": [] }`. Decoding it as a bare
    /// `EmbyConvertJob` throws `keyNotFound("Id")` because `"Id"` is not at the top level — that
    /// was the create-phase crash. This unwraps `"Job"` and returns it.
    public static func decodeCreatedJob(from data: Data) throws -> EmbyConvertJob {
        try JSONDecoder().decode(EmbyConvertJobCreationResult.self, from: data).job
    }
}

/// The `POST /Sync/Jobs` create-response envelope (`SyncJobCreationResult`): the created job is
/// nested under `"Job"` (verified live, Emby 4.9.3), distinct from the top-level shape the
/// single-job `GET /Sync/Jobs/{id}` returns. `JobItems` is intentionally ignored.
private struct EmbyConvertJobCreationResult: Decodable {
    let job: EmbyConvertJob
    enum CodingKeys: String, CodingKey {
        case job = "Job"
    }
}
