import CryptoKit
import Foundation

// MARK: - SharePlay / Watch Together pure media identity
//
// These PMSKit models are deliberately backend-agnostic and contain no server URLs,
// tokens, library ids, media-source ids, play-session ids, or raw backend item ids. The
// initial GroupActivity payload should use `SharePlayMediaActivityPayload`; the richer
// `SharePlayMediaIdentity` is a local matching hint/AVPlayerPlaybackCoordinator identity
// candidate after each participant resolves against their own library.

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
    /// The exact duration is part of the private hash seed because AVPlayerPlaybackCoordinator
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
        return milliseconds
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

/// Minimal, sanitized payload for a future `GroupActivity`. Keep matching hints out of the
/// activity itself; use local resolution before attaching AVPlayerPlaybackCoordinator.
public struct SharePlayMediaActivityPayload: Codable, Sendable, Equatable, Hashable {
    public let activityID: UUID
    public let kind: SharePlayMediaKind
    public let displayTitle: String
    public let displaySubtitle: String?

    public init(activityID: UUID = UUID(), kind: SharePlayMediaKind, displayTitle: String, displaySubtitle: String? = nil) {
        self.activityID = activityID
        self.kind = kind
        self.displayTitle = SharePlayPrivacyGuard.sanitizedDisplayText(displayTitle, fallback: "Video")
        self.displaySubtitle = displaySubtitle.map { SharePlayPrivacyGuard.sanitizedDisplayText($0, fallback: "") }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public init?(mediaItem item: MediaItem, activityID: UUID = UUID()) {
        guard let kind = SharePlayMediaKind(mediaItemType: item.type), item.isPlayableLeaf else { return nil }
        // Keep initial SharePlay activity data minimal. Exact year, duration, season/episode,
        // and provider IDs are local matching hints after join, not activity payload fields.
        self.init(activityID: activityID, kind: kind, displayTitle: item.title, displaySubtitle: nil)
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
    case failed(SharePlayResolutionFailure)
}

public struct SharePlayMediaResolver: Sendable {
    public let durationToleranceMilliseconds: Int

    /// Resolve against the caller's current library candidate set. The default timeline policy
    /// requires exact duration equality so any future AVPlayerPlaybackCoordinator item identifier
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
        guard timelineMatched.count == 1 else { return .failed(.ambiguousCandidateCount(timelineMatched.count)) }
        return .resolved(timelineMatched[0].0)
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

private enum SharePlayPrivacyGuard {
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
