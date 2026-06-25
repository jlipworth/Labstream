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

    // MARK: - #83 Original-quality compatible (remux / stream-copy) lane

    /// Video codecs that AVFoundation can both DECODE locally and that FFmpeg can stream-COPY
    /// (`-c:v copy`) into an MP4 container. Listing the source's real codec here is exactly what
    /// makes Jellyfin/Emby emit a copy instead of a re-encode, preserving original video quality.
    /// (HEVC additionally needs the `hvc1` tag fixup downstream — see `CompatibleRemuxEligibility`.)
    static let mp4CopyableVideoCodecs: Set<String> = ["h264", "hevc"]

    /// Audio codecs that can be stream-COPIED into MP4 as-is. Everything else (DTS, TrueHD, FLAC,
    /// PCM, Opus, …) is transcoded to AAC for the compatible-remux output.
    static let mp4CopyableAudioCodecs: Set<String> = ["aac", "ac3", "eac3"]

    /// Normalize a server-reported codec token to the canonical lowercase form used above,
    /// folding the common HEVC aliases (`h265`/`x265`).
    static func normalizedCodec(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        switch token {
        case "h265", "x265": return "hevc"
        case "x264", "avc": return "h264"
        default: return token
        }
    }

    /// Decide whether a source can be downloaded as an "Original quality (compatible)" MP4 — the
    /// #83 lane: COPY the video stream (original quality, no re-encode), remux into MP4, and copy or
    /// transcode-to-AAC the audio as needed. Pure + privacy-safe (codec tokens only).
    public static func compatibleRemuxEligibility(videoCodec: String?,
                                                  audioCodec: String?,
                                                  sourceContainer: String?) -> CompatibleRemuxEligibility {
        let video = normalizedCodec(videoCodec)
        let audio = normalizedCodec(audioCodec)
        let copiesVideo = video.map(mp4CopyableVideoCodecs.contains) ?? false
        let copiesAudio = audio.map(mp4CopyableAudioCodecs.contains) ?? false
        return CompatibleRemuxEligibility(
            videoCodec: video,
            audioCodec: audio,
            copiesVideo: copiesVideo,
            copiesAudio: copiesVideo ? copiesAudio : false,
            sourceContainer: containerLabel(forContainer: sourceContainer))
    }

    /// Convenience: derive the compatible-remux eligibility from a `Part`'s first video/audio
    /// streams (used by the app's download sheet/manager when full stream metadata is present).
    public static func compatibleRemuxEligibility(part: Part?) -> CompatibleRemuxEligibility {
        compatibleRemuxEligibility(videoCodec: part?.videoStreams.first?.codec,
                                   audioCodec: part?.audioStreams.first?.codec,
                                   sourceContainer: part?.container ?? (part?.file as NSString?)?.pathExtension)
    }

    /// Container token for an explicit container/extension string (no Part needed).
    static func containerLabel(forContainer raw: String?) -> String {
        let normalized = (raw ?? "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "unknown" : normalized
    }

    // MARK: - #125 Existing server-version offline gate

    /// Whether a Plex "existing server version" alternate may be downloaded byte-for-byte and still
    /// play back offline as a standalone AVFoundation asset.
    ///
    /// Unlike the byte-for-byte `.original` lane (which is backstopped by a direct-play preflight),
    /// the existing-version lane has NO preflight, so this is the only gate. It therefore FAILS
    /// CLOSED: an unknown/empty container is treated as not playable. Inputs are `Media`-level
    /// container/codec tokens (reliably present for every alternate version, no probe needed).
    ///
    /// - Parameters:
    ///   - container: `part.container ?? media.container` — the alternate's source container token.
    ///   - videoCodec: `media.videoCodec` — the alternate's source video codec token.
    /// - Returns: true only when the container is a locally-playable MP4 family *and* the video
    ///   codec is one AVFoundation can decode (`h264`/`hevc`). Privacy-safe (tokens only).
    public static func existingVersionPlayableOffline(container: String?, videoCodec: String?) -> Bool {
        let containerToken = containerLabel(forContainer: container)
        guard ["mp4", "m4v", "mov"].contains(containerToken) else { return false }
        // Fail closed on an unknown codec too — this lane has no preflight safety net.
        guard let codec = normalizedCodec(videoCodec) else { return false }
        return mp4CopyableVideoCodecs.contains(codec)
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

/// Verdict for the #83 "Original quality (compatible)" download lane: a server-side remux that
/// COPIES the video stream into an offline-playable MP4 (preserving original video quality),
/// transcoding only the audio/container as required. Privacy-safe — carries codec tokens only.
public struct CompatibleRemuxEligibility: Sendable, Equatable {
    /// Normalized source video codec token (`h264`/`hevc`/…), or nil if unknown.
    public let videoCodec: String?
    /// Normalized source audio codec token, or nil if unknown.
    public let audioCodec: String?
    /// True when the video stream can be COPIED into MP4 (no re-encode → original quality kept).
    public let copiesVideo: Bool
    /// True when the audio stream can be copied as-is; false means transcode audio to AAC.
    public let copiesAudio: Bool
    /// Normalized source container token, for diagnostics.
    public let sourceContainer: String

    /// The lane is eligible only when the video can be copied — that is the whole point (keep the
    /// original video bytes). Audio is always made compatible (copy or AAC transcode).
    public var isEligible: Bool { copiesVideo }

    /// True when audio must be transcoded to AAC for the compatible output.
    public var needsAudioTranscode: Bool { copiesVideo && !copiesAudio }

    /// True when the (copyable) video stream is HEVC — drives the post-download `hev1`→`hvc1`
    /// MP4 tag fixup that AVFoundation requires (an `hev1`-tagged HEVC track black-screens).
    public var isHEVC: Bool { copiesVideo && videoCodec == "hevc" }

    /// Whether to OFFER this lane in the UI. Pointless when the raw container is already locally
    /// playable (use the byte-for-byte original lane instead) or when the video isn't copyable.
    public func shouldOffer(originalLocallyPlayable: Bool) -> Bool {
        isEligible && !originalLocallyPlayable
    }

    /// Privacy-safe one-line codec summary for the sheet (e.g. "HEVC + AAC → MP4"). Reflects the
    /// OUTPUT audio (AAC when transcoded). nil when not eligible.
    public var codecSummary: String? {
        guard isEligible, let videoCodec else { return nil }
        let videoLabel: String
        switch videoCodec {
        case "h264": videoLabel = "H.264"
        case "hevc": videoLabel = "HEVC"
        default: videoLabel = videoCodec.uppercased()
        }
        let audioLabel: String
        if copiesAudio, let audioCodec {
            switch audioCodec {
            case "aac": audioLabel = "AAC"
            case "ac3": audioLabel = "AC-3"
            case "eac3": audioLabel = "E-AC-3"
            default: audioLabel = audioCodec.uppercased()
            }
        } else {
            audioLabel = "AAC"   // transcoded
        }
        return "\(videoLabel) + \(audioLabel) → MP4"
    }
}
