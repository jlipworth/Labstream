import Foundation

/// Privacy-safe, testable download-route facts for a Plex item part.
///
/// Streaming may be able to Direct Stream (copy video, transcode audio/remux container), but an
/// offline "original" download is only correct when the whole source file is usable byte-for-byte.
/// Keep that stricter rule in PMSKit so app UI, retry logic, and headless live probes share it.
public enum OfflineDownloadDecision {
    /// Container/extension token used for local-file compatibility checks and diagnostics.
    /// Examples: `mp4`, `mkv`, `mov`, or `unknown`; never a title/path/URL.
    public static func containerLabel(part: Part?) -> String {
        guard let part else { return "unknown" }
        let raw = (part.container?.isEmpty == false
                   ? part.container
                   : (part.file as NSString?)?.pathExtension) ?? ""
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "unknown" : normalized
    }

    /// Whether the raw source Part is a plausible local AVFoundation file on Vision Pro.
    ///
    /// PMS may stream/remux MKV through HLS, but a downloaded local MKV/TrueHD/etc. often won't
    /// open as a standalone offline file. Non-local-playable containers must render an optimized
    /// MP4 instead.
    public static func isLocallyPlayableOriginal(part: Part?) -> Bool {
        ["mp4", "m4v", "mov"].contains(containerLabel(part: part))
    }

    /// Evaluate whether the app may download the source bytes as "Original".
    public static func originalEligibility(decision: DecisionResponse, part: Part?) -> OriginalEligibility {
        OriginalEligibility(
            playsWholeFileDirectly: decision.playsWholeFileDirectly,
            localPlayableContainer: isLocallyPlayableOriginal(part: part),
            container: containerLabel(part: part),
            savesVideoEncode: decision.savesVideoEncode,
            mdeDecisionCode: decision.mdeDecisionCode,
            generalDecisionCode: decision.generalDecisionCode,
            partDecision: decision.partDecision,
            videoDecision: decision.videoDecision,
            audioDecision: decision.audioDecision)
    }
}

public struct OriginalEligibility: Sendable, Equatable {
    public let playsWholeFileDirectly: Bool
    public let localPlayableContainer: Bool
    public let container: String
    public let savesVideoEncode: Bool
    public let mdeDecisionCode: Int?
    public let generalDecisionCode: Int?
    public let partDecision: String?
    public let videoDecision: String?
    public let audioDecision: String?

    public var canDownloadOriginal: Bool {
        playsWholeFileDirectly && localPlayableContainer
    }

    /// Short privacy-safe route label for diagnostics/live probes.
    public var route: String {
        canDownloadOriginal ? "original" : "optimize"
    }

    /// Short privacy-safe reason when `route == optimize`.
    public var optimizeReason: String? {
        guard !canDownloadOriginal else { return nil }
        if !playsWholeFileDirectly {
            if savesVideoEncode { return "audio_remux" }
            return "needs_transcode"
        }
        if !localPlayableContainer { return "container_not_playable" }
        return "not_original_eligible"
    }
}
