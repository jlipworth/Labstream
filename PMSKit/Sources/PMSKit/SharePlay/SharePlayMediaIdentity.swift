import CryptoKit
import Foundation

// MARK: - SharePlay / Watch Together pure media identity
//
// These PMSKit models are deliberately backend-agnostic and contain no server URLs,
// tokens, library ids, media-source ids, play-session ids, or raw backend item ids. The
// GroupActivity payload uses `SharePlayMediaActivityPayload`, which contains only the
// explicitly allowlisted public-catalog subset needed for local resolution.

/// Media kinds that are eligible for the first Watch Together milestone.
public enum SharePlayMediaKind: String, Codable, Sendable, Equatable, Hashable, Comparable {
    case movie
    case episode

    public static func < (lhs: SharePlayMediaKind, rhs: SharePlayMediaKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Whitelisted cross-catalog provider identifiers that may be used as local matching hints.
/// Backend-local ids such as Plex `ratingKey`, Jellyfin/Emby `Id`, library ids, media-source
/// ids, and play-session ids are intentionally not representable here.
public struct SharePlayProviderID: Codable, Sendable, Equatable, Hashable, Comparable {
    public enum Provider: String, Codable, Sendable, Equatable, Hashable, Comparable, CaseIterable {
        case tmdb
        case imdb
        case tvdb

        public static func < (lhs: Provider, rhs: Provider) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let provider: Provider
    public let value: String

    public init?(provider: Provider, value: String) {
        let normalized = Self.normalizedProviderValue(value)
        guard !normalized.isEmpty else { return nil }
        self.provider = provider
        self.value = normalized
    }

    public init?(providerName: String, value: String) {
        guard let provider = Provider(rawValue: providerName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
            return nil
        }
        self.init(provider: provider, value: value)
    }

    public static func < (lhs: SharePlayProviderID, rhs: SharePlayProviderID) -> Bool {
        (lhs.provider, lhs.value) < (rhs.provider, rhs.value)
    }

    private static func normalizedProviderValue(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty,
              trimmed.count <= 64,
              !SharePlayPrivacyGuard.containsProhibitedContent(trimmed),
              trimmed.range(of: #"^[a-z0-9][a-z0-9._-]*$"#, options: .regularExpression) != nil else {
            return ""
        }
        return trimmed
    }
}

/// Local media identity used to decide whether a participant can safely resolve the same
/// logical item in their own library. It is conservative: timelines must match before a
/// resolver returns a match, and ambiguous candidates fail closed.
public struct SharePlayMediaIdentity: Codable, Sendable, Equatable, Hashable {
    public let kind: SharePlayMediaKind
    public let providerIDs: [SharePlayProviderID]
    public let normalizedTitle: String?
    public let year: Int?
    public let durationMilliseconds: Int?
    public let normalizedSeriesTitle: String?
    public let seasonNumber: Int?
    public let episodeNumber: Int?

    public init(kind: SharePlayMediaKind,
                providerIDs: [SharePlayProviderID] = [],
                normalizedTitle: String? = nil,
                year: Int? = nil,
                durationMilliseconds: Int? = nil,
                normalizedSeriesTitle: String? = nil,
                seasonNumber: Int? = nil,
                episodeNumber: Int? = nil) {
        self.kind = kind
        self.providerIDs = Array(Set(providerIDs)).sorted()
        self.normalizedTitle = Self.normalizedComparableText(normalizedTitle)
        self.year = year
        self.durationMilliseconds = Self.validDuration(durationMilliseconds)
        self.normalizedSeriesTitle = Self.normalizedComparableText(normalizedSeriesTitle)
        self.seasonNumber = Self.validNonNegative(seasonNumber)
        self.episodeNumber = Self.validNonNegative(episodeNumber)
    }

    public init?(mediaItem item: MediaItem) {
        guard let kind = SharePlayMediaKind(mediaItemType: item.type), item.isPlayableLeaf else { return nil }
        self.init(kind: kind,
                  providerIDs: SharePlayMediaIdentity.providerIDs(from: item.providerIds),
                  normalizedTitle: item.title,
                  year: item.year,
                  durationMilliseconds: item.duration,
                  normalizedSeriesTitle: item.grandparentTitle,
                  seasonNumber: item.parentIndex,
                  episodeNumber: item.index)
    }

    /// Stable opaque identifier suitable for AVPlayerPlaybackCoordinatorDelegate custom item
    /// matching. The raw logical components stay local to this process and are never exposed in
    /// the returned value.
    ///
    /// The rounded duration is part of the private hash seed because AVPlayerPlaybackCoordinator
    /// treats matching identifiers as the same timeline. This deliberately prefers false
    /// negatives (participants fail to sync until we can prove equivalence) over coordinating
    /// different cuts/editions that share provider IDs.
    public var coordinatorIdentifier: String? {
        guard let seed = coordinatorIdentifierSeed else { return nil }
        return "visionplay:coordinator:v1:\(Self.sha256Hex(seed))"
    }

    private var coordinatorIdentifierSeed: String? {
        guard durationMilliseconds != nil else { return nil }
        guard providerIDsByNamespace != nil else { return nil }
        let providerPart = providerIDs.map { "\($0.provider.rawValue):\($0.value)" }.joined(separator: ",")
        let timelinePart = "duration:\(durationMilliseconds!)"
        switch kind {
        case .movie:
            if !providerPart.isEmpty { return "movie|providers:\(providerPart)|\(timelinePart)" }
            guard let normalizedTitle, let year else { return nil }
            return "movie|title:\(Self.identifierComponent(normalizedTitle))|year:\(year)|\(timelinePart)"
        case .episode:
            guard let seasonNumber, let episodeNumber else { return nil }
            if !providerPart.isEmpty {
                return "episode|providers:\(providerPart)|s:\(seasonNumber)|e:\(episodeNumber)|\(timelinePart)"
            }
            guard let normalizedSeriesTitle else { return nil }
            return "episode|series:\(Self.identifierComponent(normalizedSeriesTitle))|s:\(seasonNumber)|e:\(episodeNumber)|\(timelinePart)"
        }
    }

    fileprivate var providerIDsByNamespace: [SharePlayProviderID.Provider: String]? {
        var values: [SharePlayProviderID.Provider: String] = [:]
        for providerID in providerIDs {
            if let existing = values[providerID.provider], existing != providerID.value {
                return nil
            }
            values[providerID.provider] = providerID.value
        }
        return values
    }

    fileprivate func hasProviderNamespaceConflict(with other: SharePlayMediaIdentity) -> Bool {
        guard let lhs = providerIDsByNamespace, let rhs = other.providerIDsByNamespace else { return true }
        for (provider, value) in lhs where rhs[provider].map({ $0 != value }) == true {
            return true
        }
        return false
    }

    fileprivate func sharesCompatibleProviderID(with other: SharePlayMediaIdentity) -> Bool {
        guard let lhs = providerIDsByNamespace, let rhs = other.providerIDsByNamespace else { return false }
        var foundSharedNamespace = false
        for (provider, value) in lhs {
            guard let otherValue = rhs[provider] else { continue }
            guard otherValue == value else { return false }
            foundSharedNamespace = true
        }
        return foundSharedNamespace
    }

    fileprivate static func providerIDs(from providerIds: [String: String]?) -> [SharePlayProviderID] {
        guard let providerIds else { return [] }
        return providerIds.compactMap { SharePlayProviderID(providerName: $0.key, value: $0.value) }.sorted()
    }

    fileprivate static func normalizedComparableText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased()
        // Comparable text stays local and only ever leaves the device SHA-256-hashed inside
        // the opaque coordinator identifier, so only hard secret markers disqualify it. The
        // broad hostname/path/filename/IP heuristics are reserved for display text, where a
        // false positive costs a generic label — here it would wrongly disable Watch Together
        // for legitimate titles like "Startup.com" or "11:14".
        guard !collapsed.isEmpty, !SharePlayPrivacyGuard.containsSecretMarker(collapsed) else { return nil }
        return collapsed
    }

    private static func validDuration(_ milliseconds: Int?) -> Int? {
        guard let milliseconds, milliseconds > 0 else { return nil }
        // Public catalog identity deliberately carries only a coarse timeline value.
        // This absorbs harmless backend rounding without disclosing exact server data.
        let bucket = 5_000
        return Int((Double(milliseconds) / Double(bucket)).rounded()) * bucket
    }

    private static func validNonNegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func identifierComponent(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"[^a-z0-9._-]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func sha256Hex(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension SharePlayMediaKind {
    fileprivate init?(mediaItemType: String) {
        switch mediaItemType {
        case "movie": self = .movie
        case "episode": self = .episode
        default: return nil
        }
    }
}

/// Sanitized GroupActivity payload containing only disclosed public-catalog matching fields.
public struct SharePlayMediaActivityPayload: Codable, Sendable, Equatable, Hashable {
    public let activityID: UUID
    public let identity: SharePlayMediaIdentity
    public let displayTitle: String
    public let displaySubtitle: String?

    public init(activityID: UUID = UUID(), identity: SharePlayMediaIdentity,
                displayTitle: String, displaySubtitle: String? = nil) {
        self.activityID = activityID
        self.identity = identity
        self.displayTitle = SharePlayPrivacyGuard.sanitizedDisplayText(displayTitle, fallback: "Video")
        self.displaySubtitle = displaySubtitle.map { SharePlayPrivacyGuard.sanitizedDisplayText($0, fallback: "") }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public init?(mediaItem item: MediaItem, activityID: UUID = UUID()) {
        // A joiner must see the real shared title. If it resembles a private URL,
        // path, filename, credential, or backend identifier, fail closed rather
        // than replacing it with a misleading generic label.
        guard !SharePlayPrivacyGuard.containsProhibitedContent(item.title) else { return nil }
        guard let localIdentity = SharePlayMediaIdentity(mediaItem: item) else { return nil }
        // The richer local identity tolerates title-shaped false positives because it
        // was originally hash-only. Activity identity crosses devices, so comparable
        // text is separately gated by the strict display privacy policy.
        let identity = SharePlayMediaIdentity(
            kind: localIdentity.kind,
            providerIDs: localIdentity.providerIDs,
            normalizedTitle: SharePlayPrivacyGuard.shareableComparableText(item.title),
            year: localIdentity.year,
            durationMilliseconds: localIdentity.durationMilliseconds,
            normalizedSeriesTitle: SharePlayPrivacyGuard.shareableComparableText(item.grandparentTitle),
            seasonNumber: localIdentity.seasonNumber,
            episodeNumber: localIdentity.episodeNumber)
        let subtitle: String?
        switch identity.kind {
        case .movie:
            subtitle = identity.year.map(String.init)
        case .episode:
            let numbers = [identity.seasonNumber.map { "S\($0)" },
                           identity.episodeNumber.map { "E\($0)" }]
                .compactMap { $0 }.joined()
            subtitle = [item.grandparentTitle, numbers.isEmpty ? nil : numbers]
                .compactMap { $0 }.joined(separator: " · ")
        }
        self.init(activityID: activityID, identity: identity,
                  displayTitle: item.title, displaySubtitle: subtitle)
    }
}

public enum SharePlayResolutionFailure: Sendable, Equatable, Hashable {
    case unsupportedIdentity
    case missingTimeline
    case notFound
    case ambiguousCandidateCount(Int)
    case timelineMismatch
}

public enum SharePlayMediaResolution: Sendable {
    case resolved(MediaItem)
    case selectionRequired([MediaItem])
    case failed(SharePlayResolutionFailure)
}

public struct SharePlayMediaResolver: Sendable {
    public let durationToleranceMilliseconds: Int

    /// Resolve against the caller's current library candidate set. The default timeline policy
    /// requires equality of the rounded duration bucket so any AVPlayerPlaybackCoordinator identifier
    /// produced from the resolved item is consistent with resolver semantics. A non-zero tolerance
    /// should only be used after backend-specific duration rounding has been validated.
    public init(durationToleranceMilliseconds: Int = 0) {
        self.durationToleranceMilliseconds = max(0, durationToleranceMilliseconds)
    }

    public func resolve(_ identity: SharePlayMediaIdentity, in candidates: [MediaItem]) -> SharePlayMediaResolution {
        guard identity.durationMilliseconds != nil else { return .failed(.missingTimeline) }
        guard identity.coordinatorIdentifier != nil else { return .failed(.unsupportedIdentity) }

        let typedCandidates = candidates.compactMap { item -> (MediaItem, SharePlayMediaIdentity)? in
            guard let candidateIdentity = SharePlayMediaIdentity(mediaItem: item), candidateIdentity.kind == identity.kind else {
                return nil
            }
            return (item, candidateIdentity)
        }

        let logicallyMatched = typedCandidates.filter { _, candidateIdentity in
            isLogicalMatch(identity, candidateIdentity)
        }
        guard !logicallyMatched.isEmpty else { return .failed(.notFound) }

        let timelineMatched = logicallyMatched.filter { _, candidateIdentity in
            timelinesMatch(identity.durationMilliseconds, candidateIdentity.durationMilliseconds)
        }
        guard !timelineMatched.isEmpty else { return .failed(.timelineMismatch) }
        guard timelineMatched.count == 1 else {
            return .selectionRequired(timelineMatched.map(\.0))
        }
        return .resolved(timelineMatched[0].0)
    }

    /// Candidates safe enough to offer for explicit local confirmation. Logical
    /// identity may be incomplete, but kind and rounded timeline must agree.
    public func selectableCandidates(for identity: SharePlayMediaIdentity,
                                     in candidates: [MediaItem]) -> [MediaItem] {
        candidates.filter { item in
            guard let candidate = SharePlayMediaIdentity(mediaItem: item),
                  candidate.kind == identity.kind else { return false }
            return timelinesMatch(identity.durationMilliseconds, candidate.durationMilliseconds)
        }
    }

    private func isLogicalMatch(_ requested: SharePlayMediaIdentity, _ candidate: SharePlayMediaIdentity) -> Bool {
        guard !requested.hasProviderNamespaceConflict(with: candidate) else { return false }
        switch requested.kind {
        case .movie:
            if requested.sharesCompatibleProviderID(with: candidate) { return true }
            return requested.normalizedTitle != nil
                && requested.normalizedTitle == candidate.normalizedTitle
                && requested.year != nil
                && requested.year == candidate.year
        case .episode:
            guard requested.seasonNumber != nil,
                  requested.seasonNumber == candidate.seasonNumber,
                  requested.episodeNumber != nil,
                  requested.episodeNumber == candidate.episodeNumber else {
                return false
            }
            if requested.sharesCompatibleProviderID(with: candidate) { return true }
            return requested.normalizedSeriesTitle != nil
                && requested.normalizedSeriesTitle == candidate.normalizedSeriesTitle
                && requested.normalizedTitle != nil
                && requested.normalizedTitle == candidate.normalizedTitle
        }
    }

    private func timelinesMatch(_ lhs: Int?, _ rhs: Int?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs - rhs) <= durationToleranceMilliseconds
    }
}

extension MediaItem {
    public var sharePlayMediaIdentity: SharePlayMediaIdentity? {
        SharePlayMediaIdentity(mediaItem: self)
    }

    public var sharePlayActivityPayload: SharePlayMediaActivityPayload? {
        SharePlayMediaActivityPayload(mediaItem: self)
    }
}

public enum SharePlayParticipantReadiness: String, Codable, Sendable {
    case resolving, ready, unable, started
}

/// Reconciles readiness messages with the authoritative GroupSession participant roster.
/// A participant is considered resolving from the moment they appear in the session, rather
/// than only after their first messenger status arrives. This closes the race where an initiator
/// could see zero unresolved participants and start immediately while a newly joined participant's
/// `.resolving` message was still in flight. Departed participants are removed deterministically.
public enum SharePlayReadinessRoster {
    public static func reconcile(statuses: [UUID: SharePlayParticipantReadiness],
                                 activeParticipantIDs: Set<UUID>,
                                 localParticipantID: UUID) -> [UUID: SharePlayParticipantReadiness] {
        let allowed = activeParticipantIDs.union([localParticipantID])
        var reconciled = statuses.filter { allowed.contains($0.key) }
        for participantID in activeParticipantIDs where participantID != localParticipantID {
            if reconciled[participantID] == nil {
                reconciled[participantID] = .resolving
            }
        }
        return reconciled
    }
}

/// Pure policy for the readiness gate. An unresolved capable participant requires
/// explicit acknowledgement, while unable participants never block forever. A late
/// participant launches locally once it resolves after the group has started.
public struct SharePlayReadinessSummary: Sendable, Equatable {
    public let readyCount: Int
    public let resolvingCount: Int
    public let unableCount: Int

    public init(statuses: [SharePlayParticipantReadiness]) {
        readyCount = statuses.filter { $0 == .ready || $0 == .started }.count
        resolvingCount = statuses.filter { $0 == .resolving }.count
        unableCount = statuses.filter { $0 == .unable }.count
    }

    public func canStart(acknowledgingUnresolved: Bool) -> Bool {
        readyCount > 0 && (resolvingCount == 0 || acknowledgingUnresolved)
    }

    public static func shouldLaunchLocally(sessionStarted: Bool, localResolved: Bool) -> Bool {
        sessionStarted && localResolved
    }
}

/// Decision for a player dismissal that reports it was showing the session's resolved item.
/// A dismissal only ends the session when it comes from the player minted by the coordinator's
/// CURRENT launch. When the coordinator supersedes a pre-launch player by launching its own player
/// for the same item, the old player was created under an earlier launch epoch, so its teardown
/// dismissal is suppressed instead of destroying the freshly joined session. Comparing epochs
/// (rather than consuming a one-shot pending flag) is order-independent: it never swallows a
/// genuine close of the replacement player when no superseded player existed (the flag did, leaving
/// a ghost participant while the first item was still minting), and it keeps suppressing the
/// superseded dismissal regardless of whether the replacement has attached yet.
public enum SharePlayLeaveDecision {
    public enum Outcome: Equatable, Sendable {
        /// The dismissed item is not the resolved item; ignore it entirely.
        case ignore
        /// The dismissal is a superseded player from an earlier launch epoch tearing down;
        /// suppress the leave.
        case suppressSupersededDismissal
        /// A genuine end of participation; leave the session.
        case leave
    }

    /// `dismissingPlayerLaunchEpoch` is the coordinator launch epoch the dismissing player surface
    /// captured when its controller was created (`nil` when it never captured one, which only a
    /// current-launch surface that failed to start playback can produce — treated as genuine).
    public static func evaluate(resolvedMatchesItem: Bool,
                                dismissingPlayerLaunchEpoch: UInt64?,
                                currentLaunchEpoch: UInt64) -> Outcome {
        guard resolvedMatchesItem else { return .ignore }
        if let epoch = dismissingPlayerLaunchEpoch, epoch != currentLaunchEpoch {
            return .suppressSupersededDismissal
        }
        return .leave
    }
}

/// Gate for binding a local AVPlayer to the group session: only a player created under the
/// coordinator's CURRENT launch epoch may attach. The superseded pre-launch player runs the same
/// attachment-maintenance poll over the same resolved item, so item identity alone cannot tell it
/// apart from the replacement — the instant launch consent flips it could attach first, get its
/// coordination torn down by its own imminent dismissal, and starve the real replacement.
public enum SharePlayAttachmentPolicy {
    public static func mayAttach(playerLaunchEpoch: UInt64?, currentLaunchEpoch: UInt64) -> Bool {
        playerLaunchEpoch == currentLaunchEpoch
    }
}

/// Whether a failed/cancelled activation may restore its `.unavailable` failure state. A
/// GroupSession installed WHILE the activation was suspended (a remote activity arrived, or our
/// own activity resolved) advances the session generation and owns `state`; replaying the failure
/// over it would hide the joined session and let a second tap replace the live activity. A session
/// that merely PREDATES the activation attempt must not block restoration — otherwise cancelling
/// the FaceTime sheet leaves the coordinator in `.resolving` forever with no affordance.
public enum SharePlayActivationFailurePolicy {
    public static func shouldRestoreFailureState(sessionGenerationAtRequest: UInt64,
                                                 currentSessionGeneration: UInt64) -> Bool {
        sessionGenerationAtRequest == currentSessionGeneration
    }
}

/// Selects which started participant re-announces `.started` to a newcomer. Any participant that has
/// launched may re-broadcast (not only the initiator, who may have left), but only the one with the
/// lowest identifier does so, so N started participants don't each send a duplicate. Receivers stay
/// idempotent, so a transient disagreement about the started set is harmless.
public enum SharePlayStartedBroadcast {
    public static func shouldRebroadcast(localID: UUID, startedParticipantIDs: Set<UUID>) -> Bool {
        guard startedParticipantIDs.contains(localID) else { return false }
        return startedParticipantIDs.min(by: { $0.uuidString < $1.uuidString }) == localID
    }
}

private enum SharePlayPrivacyGuard {
    static func shareableComparableText(_ raw: String?) -> String? {
        guard let raw, !containsProhibitedContent(raw) else { return nil }
        return raw
    }

    static func sanitizedDisplayText(_ raw: String, fallback: String, maxLength: Int = 120) -> String {
        let collapsed = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard !collapsed.isEmpty, !containsProhibitedContent(collapsed) else { return fallback }
        if collapsed.count <= maxLength { return collapsed }
        return String(collapsed.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func containsProhibitedContent(_ text: String) -> Bool {
        if containsSecretMarker(text) {
            return true
        }
        if DiagnosticRedactor.redact(text) != text {
            return true
        }
        let lowered = text.lowercased()
        return heuristicPatterns.contains {
            $0.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil
        }
    }

    /// Hard, low-false-positive markers of leaked credentials or backend identifiers — the
    /// checks that apply even to matching text that never leaves the device unhashed. The
    /// broader hostname/IP/path/filename heuristics (including DiagnosticRedactor, which
    /// shares them) only gate display text via `containsProhibitedContent`.
    static func containsSecretMarker(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if secretPatterns.contains(where: { $0.firstMatch(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) != nil }) {
            return true
        }
        if lowered.contains("x-plex-token")
            || lowered.contains("token=")
            || lowered.contains("access_token")
            || lowered.contains("playsessionid")
            || lowered.contains("play-session")
            || lowered.contains("mediasourceid")
            || lowered.contains("librarysection")
            || lowered.contains("ratingkey")
            || lowered.contains("rating_key")
            || lowered.contains("backend item")
            || lowered.contains("backend_id")
            || lowered.contains("backendid")
            || lowered.contains("item id")
            || lowered.contains("item_id")
            || lowered.contains("library id")
            || lowered.contains("library_id")
            || lowered.contains("api key")
            || lowered.contains("apikey")
            || lowered.contains("client id")
            || lowered.contains("client_id")
            || lowered.contains("client identifier")
            || lowered.contains("client_identifier")
            || lowered.contains("password=")
            || lowered.contains("password:") {
            return true
        }
        return false
    }

    private static let secretPatterns: [NSRegularExpression] = [
        #"[a-z][a-z0-9+.-]*://"#,
        #"\b(?:x-plex-token|tokens?|access[_-]?token|api[_-]?key|apikey|password|passwd|pwd|secret|client[_-]?identifier)\s*[=:]\s*\S+"#,
        #"\bauthorization\b\s*:?\s*(?:bearer\b|\S+)"#
    ].map { try! NSRegularExpression(pattern: $0) }

    /// Precompiled once: these run on every identity/payload construction, and DetailView
    /// re-evaluates identities per render — recompiling ten regexes each time is measurable
    /// main-thread work.
    private static let heuristicPatterns: [NSRegularExpression] = [
        #"https?://"#,
        #"[a-z][a-z0-9+.-]*://"#,
        #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#,
        #"\b(?:[0-9a-f]{0,4}:){2,}[0-9a-f]{0,4}\b"#,
        #"\b[a-z0-9.-]+\.(?:local|internal|lan|home|example|com|net|org|io|tv|me|dev|app|co|us|uk|ca|de|fr|es|it|nl|au|eu|se|ch|info|biz|xyz|cloud|site|online|live|pro|direct)(?:[:/]|\b)"#,
        #"\b[a-z0-9-]{2,}:\d{2,5}\b"#,
        #"(?i)(?:^|[\s])(?:/Users/|/home/|/Volumes/|/mnt/|/media/|/storage/|/private/|/var/|/tmp/|/library/|/metadata/|/transcode/|/video/|/items/)[^\s]*"#,
        #"(?i)\b[A-Z]:\\[^\s]+"#,
        #"(?i)\b[^\s/\\]+\.(?:mkv|mp4|m4v|mov|avi|ts|m3u8|mp3|flac|srt|ass|jpg|jpeg|png|webp|nfo)\b"#,
        #"(?i)\b(?:ratingkey|rating_key|itemid|item_id|libraryid|library_id|mediaid|media_id|mediasourceid|media_source_id|playsessionid|play_session_id|api[_ -]?key|client[_ -]?(?:id|identifier)|password|passwd|pwd)\s*[:=]\s*\S+"#
    ].map { try! NSRegularExpression(pattern: $0) }
}
