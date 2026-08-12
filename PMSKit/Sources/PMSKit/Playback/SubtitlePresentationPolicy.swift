import Foundation

/// Facts about how a subtitle choice reaches the screen. These are transport facts, not codec
/// guesses: callers may use container metadata to select a case only when the backend contract or
/// a returned playback decision proves it.
public enum SubtitleDeliveryRoute: Sendable, Equatable {
    case off
    case avFoundationSoft
    case offlineTextSidecar
    case plexMetadata
    case jellyfinMetadata
    case embyEncodedSelection
}

/// Server evidence associated with the currently active subtitle selection.
public enum SubtitleServerEvidence: Sendable, Equatable {
    case unavailable
    case videoCopyOrDirect
    case videoTranscode(subtitleDecision: String?, reasons: [String])

    public var provesSubtitleBurn: Bool {
        switch self {
        case .unavailable, .videoCopyOrDirect:
            return false
        case .videoTranscode(let subtitleDecision, let reasons):
            let normalizedDecision = subtitleDecision?
                .lowercased().replacingOccurrences(of: " ", with: "")
            if ["burn", "burnin", "transcode", "encode"].contains(normalizedDecision) {
                return true
            }
            return reasons.contains { reason in
                let normalized = reason.lowercased()
                return normalized.contains("subtitle")
                    && (normalized.contains("burn")
                        || normalized.contains("codec")
                        || normalized.contains("not supported"))
            }
        }
    }
}

/// Issue #248's typed playback-consequence policy. It intentionally remains separate from
/// `SubtitleStyleCapabilityPolicy`: burning affects the transport lane; styling describes who
/// owns caption appearance.
public enum SubtitleBurnRiskPolicy {
    public enum Verdict: Sendable, Equatable {
        case none
        case uncertain
        case required

        public var badgeText: String? {
            switch self {
            case .none: nil
            case .uncertain: "May require video processing"
            case .required: "Requires video processing"
            }
        }
    }

    public static func verdict(route: SubtitleDeliveryRoute,
                               isCurrentSelection: Bool,
                               serverEvidence: SubtitleServerEvidence,
                               explicitlyRequestsBurn: Bool = false) -> Verdict {
        switch route {
        case .off, .avFoundationSoft, .offlineTextSidecar:
            return .none
        case .embyEncodedSelection:
            // Emby's advertised streaming profile declares every selected subtitle as Encode.
            return .required
        case .plexMetadata, .jellyfinMetadata:
            if explicitlyRequestsBurn { return .required }
            if isCurrentSelection, serverEvidence.provesSubtitleBurn { return .required }
            if case .videoCopyOrDirect = serverEvidence, isCurrentSelection { return .none }
            return .uncertain
        }
    }

    /// Confirm only when the candidate is known to introduce video encoding. An already encoded
    /// video lane is not materially changed, and reselecting the active row is a no-op.
    public static func shouldConfirm(candidate: Verdict,
                                     isAlreadySelected: Bool,
                                     activeVideoIsTranscoding: Bool) -> Bool {
        candidate == .required && !isAlreadySelected && !activeVideoIsTranscoding
    }
}

/// Issue #260's distinct appearance-ownership policy.
public enum SubtitleStyleCapabilityPolicy {
    public enum Capability: Sendable, Equatable {
        case nativeAVFoundationPreview
        case offlineSystemProfile
        case unavailableServerOrSourceRendered
        case unavailableUntilDeliveryIsKnown

        public var explanatoryText: String? {
            switch self {
            case .nativeAVFoundationPreview, .offlineSystemProfile:
                nil
            case .unavailableServerOrSourceRendered:
                "Appearance is controlled by the server or subtitle source and cannot be changed after delivery."
            case .unavailableUntilDeliveryIsKnown:
                "Caption appearance becomes available only when the server delivers a selectable text track."
            }
        }
    }

    public static func capability(route: SubtitleDeliveryRoute,
                                  burnVerdict: SubtitleBurnRiskPolicy.Verdict,
                                  isImageOrAuthoredStyle: Bool = false) -> Capability {
        if isImageOrAuthoredStyle || burnVerdict == .required {
            return .unavailableServerOrSourceRendered
        }
        switch route {
        case .off, .avFoundationSoft:
            return .nativeAVFoundationPreview
        case .offlineTextSidecar:
            return .offlineSystemProfile
        case .embyEncodedSelection:
            return .unavailableServerOrSourceRendered
        case .plexMetadata, .jellyfinMetadata:
            return burnVerdict == .none
                ? .nativeAVFoundationPreview
                : .unavailableUntilDeliveryIsKnown
        }
    }
}
