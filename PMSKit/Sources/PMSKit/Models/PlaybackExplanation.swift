import Foundation

/// Privacy-safe provenance for one normalized playback explanation fact.
public enum PlaybackExplanationProvenance: String, Sendable, Equatable, CaseIterable {
    case serverReported = "server_reported"
    case labstreamRequested = "labstream_requested"
    case inferred
    case unknown
}

/// The active playback lane. These values deliberately describe media work rather than a
/// backend endpoint or session so they are safe to include in diagnostics exports.
public enum PlaybackExplanationLane: String, Sendable, Equatable {
    case directPlay = "direct_play"
    case directStream = "direct_stream"
    case audioOnlyTranscode = "audio_only_transcode"
    case videoTranscode = "video_transcode"
    case unknownTranscode = "unknown_transcode"
}

/// Small semantic reason set shared by Plex, Jellyfin, and Emby.
///
/// Associated data is limited to an app-requested bitrate cap. Raw backend prose, URLs,
/// identifiers, titles, paths, server names, and client identifiers cannot enter this model.
public enum PlaybackExplanationReason: Sendable, Equatable {
    case originalFile
    case videoCopy
    case audioTranscode
    case videoTranscode
    case containerOrProtocol
    case videoCodec
    case videoProfileOrLevel
    case videoResolution
    case videoBitDepth
    case videoFrameRate
    case videoRangeOrHDR
    case videoLayout
    case audioCodec
    case audioChannels
    case audioProfile
    case audioRateOrDepth
    case audioBitrate
    case externalOrSecondaryAudio
    case subtitleCompatibility
    case subtitleBurnIn
    case bitrateLimit
    case qualityCap(kbps: Int)
    case dolbyVisionGuard
    case unknownServerReason

    public var diagnosticBucket: String {
        switch self {
        case .originalFile: "original_file"
        case .videoCopy: "video_copy"
        case .audioTranscode: "audio_transcode"
        case .videoTranscode: "video_transcode"
        case .containerOrProtocol: "container_or_protocol"
        case .videoCodec: "video_codec"
        case .videoProfileOrLevel: "video_profile_or_level"
        case .videoResolution: "video_resolution"
        case .videoBitDepth: "video_bit_depth"
        case .videoFrameRate: "video_frame_rate"
        case .videoRangeOrHDR: "video_range_or_hdr"
        case .videoLayout: "video_layout"
        case .audioCodec: "audio_codec"
        case .audioChannels: "audio_channels"
        case .audioProfile: "audio_profile"
        case .audioRateOrDepth: "audio_rate_or_depth"
        case .audioBitrate: "audio_bitrate"
        case .externalOrSecondaryAudio: "external_or_secondary_audio"
        case .subtitleCompatibility: "subtitle_compatibility"
        case .subtitleBurnIn: "subtitle_burn_in"
        case .bitrateLimit: "bitrate_limit"
        case .qualityCap: "quality_cap"
        case .dolbyVisionGuard: "dolby_vision_guard"
        case .unknownServerReason: "unknown_server_reason"
        }
    }

    public var conciseText: String {
        switch self {
        case .originalFile:
            return "The original file is playing without a server transcode."
        case .videoCopy:
            return "Video is copied without re-encoding, so its quality is unchanged."
        case .audioTranscode:
            return "The selected audio is being converted for this playback path."
        case .videoTranscode:
            return "The server reports that video is being re-encoded."
        case .containerOrProtocol:
            return "The source container or streaming protocol is not compatible with this path."
        case .videoCodec:
            return "The source video codec is not compatible with this playback path."
        case .videoProfileOrLevel:
            return "The source video profile or level is not compatible."
        case .videoResolution:
            return "The source video resolution exceeds a playback limit."
        case .videoBitDepth:
            return "The source video bit depth is not compatible."
        case .videoFrameRate:
            return "The source video frame rate is not compatible."
        case .videoRangeOrHDR:
            return "The source HDR or video-range format is not compatible with this path."
        case .videoLayout:
            return "The source video layout requires server processing."
        case .audioCodec:
            return "The selected audio codec is not compatible with this playback path."
        case .audioChannels:
            return "The selected audio channel layout is not compatible."
        case .audioProfile:
            return "The selected audio profile is not compatible."
        case .audioRateOrDepth:
            return "The selected audio sample format is not compatible."
        case .audioBitrate:
            return "The selected audio bitrate exceeds a playback limit."
        case .externalOrSecondaryAudio:
            return "The selected external or secondary audio stream requires conversion."
        case .subtitleCompatibility:
            return "The selected subtitles require server processing and may require video re-encoding."
        case .subtitleBurnIn:
            return "Labstream requested subtitle burn-in, so the server must re-encode video."
        case .bitrateLimit:
            return "The source exceeds a server-reported bitrate limit."
        case .qualityCap(let kbps):
            let value = max(0, kbps)
            if value >= 1_000 {
                let mbps = Double(value) / 1_000
                let label = mbps.rounded() == mbps ? String(Int(mbps)) : String(format: "%.1f", mbps)
                return "Labstream requested a \(label) Mbps quality cap."
            }
            return "Labstream requested a \(value) kbps quality cap."
        case .dolbyVisionGuard:
            return "Labstream requested server tone-mapping because this Dolby Vision source is not safe on the current path."
        case .unknownServerReason:
            return "The server did not report a specific cause."
        }
    }
}

public struct PlaybackExplanationEvidence: Sendable, Equatable {
    public let reason: PlaybackExplanationReason
    public let provenance: PlaybackExplanationProvenance

    public init(reason: PlaybackExplanationReason,
                provenance: PlaybackExplanationProvenance) {
        self.reason = reason
        self.provenance = provenance
    }

    /// Stable, privacy-safe export token. It contains only closed enums and a bucket name.
    public var diagnosticToken: String {
        "\(provenance.rawValue):\(reason.diagnosticBucket)"
    }

    /// Confidence-aware player wording. Runtime codec agreement is only a copy signal, not
    /// proof of the backend's encoder decision, so inferred copy facts must say "likely".
    public var conciseText: String {
        if provenance == .inferred, reason == .videoCopy {
            return "The rendered video codec matches the source, so video is likely being copied."
        }
        return reason.conciseText
    }
}

public struct PlaybackExplanation: Sendable, Equatable {
    public let lane: PlaybackExplanationLane
    public let evidence: [PlaybackExplanationEvidence]

    public init(lane: PlaybackExplanationLane,
                evidence: [PlaybackExplanationEvidence]) {
        self.lane = lane
        self.evidence = Self.deduplicated(evidence)
    }

    public var headline: String {
        switch lane {
        case .directPlay:
            "Playing the original file"
        case .directStream:
            evidence.contains(.init(reason: .videoCopy, provenance: .inferred))
                ? "Video is likely copied; the stream is repackaged"
                : "Video is copied; the stream is repackaged"
        case .audioOnlyTranscode:
            evidence.contains(.init(reason: .videoCopy, provenance: .inferred))
                ? "Video is likely copied; audio is converted"
                : "Video is copied; audio is converted"
        case .videoTranscode:
            "The server is re-encoding video"
        case .unknownTranscode:
            "The server selected a transcode"
        }
    }

    /// The normal player UI intentionally shows no more than two useful reasons.
    public var conciseReasons: [PlaybackExplanationEvidence] {
        Array(evidence.prefix(2))
    }

    public var diagnosticTokens: [String] {
        evidence.map(\.diagnosticToken)
    }

    public static func plex(decision: DecisionResponse?,
                            maxVideoBitrateKbps: Int,
                            subtitleBurnRequested: Bool,
                            dolbyVisionGuardActive: Bool,
                            decisionUnavailableMeansTranscode: Bool = false) -> PlaybackExplanation {
        let lane = plexLane(decision,
                            decisionUnavailableMeansTranscode: decisionUnavailableMeansTranscode)
        var facts: [PlaybackExplanationEvidence] = []

        if dolbyVisionGuardActive {
            facts.append(.init(reason: .dolbyVisionGuard, provenance: .labstreamRequested))
        }
        if subtitleBurnRequested, lane == .videoTranscode || lane == .unknownTranscode {
            facts.append(.init(reason: .subtitleBurnIn, provenance: .labstreamRequested))
        }
        if maxVideoBitrateKbps > 0, lane == .videoTranscode || lane == .unknownTranscode {
            facts.append(.init(reason: .qualityCap(kbps: maxVideoBitrateKbps),
                               provenance: .labstreamRequested))
        }

        switch lane {
        case .directPlay:
            facts.append(.init(reason: .originalFile, provenance: decision == nil ? .inferred : .serverReported))
        case .directStream:
            facts.append(.init(reason: .videoCopy, provenance: .serverReported))
        case .audioOnlyTranscode:
            facts.append(.init(reason: .videoCopy, provenance: .serverReported))
            facts.append(.init(reason: .audioTranscode, provenance: .serverReported))
        case .videoTranscode:
            facts.append(.init(reason: .videoTranscode, provenance: .serverReported))
        case .unknownTranscode:
            facts.append(.init(reason: .unknownServerReason, provenance: .unknown))
        }
        return PlaybackExplanation(lane: lane, evidence: facts)
    }

    public static func mediaBrowser(playMethod: MediaBrowserPlayMethod,
                                    transcodeReasons: [String],
                                    maxVideoBitrateKbps: Int,
                                    dolbyVisionGuardActive: Bool) -> PlaybackExplanation {
        var facts: [PlaybackExplanationEvidence] = []
        if dolbyVisionGuardActive, playMethod == .transcode {
            facts.append(.init(reason: .dolbyVisionGuard, provenance: .labstreamRequested))
        }
        if maxVideoBitrateKbps > 0, playMethod == .transcode {
            facts.append(.init(reason: .qualityCap(kbps: maxVideoBitrateKbps),
                               provenance: .labstreamRequested))
        }
        facts.append(contentsOf: normalizedMediaBrowserReasons(transcodeReasons).map {
            PlaybackExplanationEvidence(reason: $0, provenance: .serverReported)
        })

        let lane: PlaybackExplanationLane
        switch playMethod {
        case .directPlay:
            lane = .directPlay
            facts.append(.init(reason: .originalFile, provenance: .serverReported))
        case .directStream:
            lane = .directStream
            facts.append(.init(reason: .videoCopy, provenance: .serverReported))
        case .transcode:
            let hasVideoCause = facts.contains {
                $0.provenance == .serverReported && $0.reason.isVideoCause
            }
            let hasAudioCause = facts.contains { $0.reason.isAudioCause }
            if hasAudioCause && !hasVideoCause {
                lane = .audioOnlyTranscode
                facts.append(.init(reason: .videoCopy, provenance: .inferred))
                facts.append(.init(reason: .audioTranscode, provenance: .serverReported))
            } else if hasVideoCause || dolbyVisionGuardActive {
                lane = .videoTranscode
                facts.append(.init(reason: .videoTranscode, provenance: .serverReported))
            } else {
                lane = .unknownTranscode
                facts.append(.init(reason: .unknownServerReason, provenance: .unknown))
            }
        }
        return PlaybackExplanation(lane: lane, evidence: facts)
    }

    /// Runtime codec-family agreement can make video copy plausible, but it cannot establish why
    /// the server selected the lane. Preserve all server/app causes and tag the refinement inferred.
    public func refinedWithRuntimeVideoCopy() -> PlaybackExplanation {
        guard lane == .videoTranscode || lane == .unknownTranscode else { return self }
        let audioCause = evidence.contains { $0.reason.isAudioCause }
        var facts = evidence.filter { $0.reason != .videoTranscode && $0.reason != .unknownServerReason }
        facts.append(.init(reason: .videoCopy, provenance: .inferred))
        if audioCause {
            facts.append(.init(reason: .audioTranscode, provenance: .serverReported))
        }
        return PlaybackExplanation(lane: audioCause ? .audioOnlyTranscode : .directStream,
                                   evidence: facts)
    }

    private static func plexLane(_ decision: DecisionResponse?,
                                 decisionUnavailableMeansTranscode: Bool) -> PlaybackExplanationLane {
        guard let decision else {
            return decisionUnavailableMeansTranscode ? .unknownTranscode : .directPlay
        }
        if decision.playsWholeFileDirectly { return .directPlay }
        let video = normalizedDecision(decision.videoDecision)
        let audio = normalizedDecision(decision.audioDecision)
        if video == "copy" || video == "directplay" {
            return audio == "transcode" ? .audioOnlyTranscode : .directStream
        }
        if decision.savesVideoEncode { return .directStream }
        if video == "transcode" { return .videoTranscode }
        if decision.decision == .transcode { return .unknownTranscode }
        return .unknownTranscode
    }

    private static func normalizedDecision(_ value: String?) -> String? {
        value?.lowercased().filter(\.isLetter)
    }

    private static func normalizedMediaBrowserReasons(_ rawReasons: [String]) -> [PlaybackExplanationReason] {
        rawReasons.compactMap { raw in
            let value = raw.lowercased().filter(\.isLetter)
            switch value {
            case "containernotsupported", "directstreamfailure", "protocolnotsupported":
                return .containerOrProtocol
            case "containerbitrateexceedslimit":
                return .bitrateLimit
            case "videocodecnotsupported", "videotagnotsupported":
                return .videoCodec
            case "videoprofilenotsupported", "videolevelnotsupported", "videorefframesnotsupported":
                return .videoProfileOrLevel
            case "videoresolutionnotsupported":
                return .videoResolution
            case "videobitdepthnotsupported":
                return .videoBitDepth
            case "videoframeratenotsupported":
                return .videoFrameRate
            case "videorangenotsupported", "videorangenotallowed", "hdrnotsupported":
                return .videoRangeOrHDR
            case "videoanamorphicnotsupported", "videointerlacednotsupported", "videorotationnotsupported":
                return .videoLayout
            case "audiocodecnotsupported":
                return .audioCodec
            case "audiochannelsnotsupported":
                return .audioChannels
            case "audioprofilenotsupported":
                return .audioProfile
            case "audiosampleratenotsupported", "audiobitdepthnotsupported":
                return .audioRateOrDepth
            case "audiobitrateexceedslimit":
                return .audioBitrate
            case "externalaudionotsupported", "secondaryaudionotsupported", "audiodelaynotsupported":
                return .externalOrSecondaryAudio
            case "subtitlecodecnotsupported", "subtitlecontentoptionsenabled":
                return .subtitleCompatibility
            case "bitrateexceedslimit", "videobitrateexceedslimit":
                return .bitrateLimit
            case "unknownvideostreaminfo", "unknownaudiostreaminfo", "directplayerror", "unknown":
                return .unknownServerReason
            default:
                return nil
            }
        }
    }

    private static func deduplicated(_ facts: [PlaybackExplanationEvidence]) -> [PlaybackExplanationEvidence] {
        var seen = Set<String>()
        return facts.filter { seen.insert($0.diagnosticToken).inserted }
    }
}

private extension PlaybackExplanationReason {
    var isVideoCause: Bool {
        switch self {
        case .videoCodec, .videoProfileOrLevel, .videoResolution, .videoBitDepth,
             .videoFrameRate, .videoRangeOrHDR, .videoLayout, .subtitleCompatibility,
             .subtitleBurnIn, .bitrateLimit, .qualityCap, .dolbyVisionGuard:
            true
        default:
            false
        }
    }

    var isAudioCause: Bool {
        switch self {
        case .audioCodec, .audioChannels, .audioProfile, .audioRateOrDepth,
             .audioBitrate, .externalOrSecondaryAudio:
            true
        default:
            false
        }
    }
}
