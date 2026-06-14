import Foundation

/// The high-level outcome of a transcode-decision call.
public enum Decision: Sendable, Equatable {
    /// PMS will stream the file as-is (general decision code ~1000).
    case directPlay
    /// PMS will transcode the file (general decision code ~1001).
    case transcode
    /// Any other / error decision code.
    case unsupported(code: Int)

    /// Map a PMS `generalDecisionCode` to a `Decision`.
    public init(generalDecisionCode: Int) {
        switch generalDecisionCode {
        case 1000: self = .directPlay
        case 1001: self = .transcode
        default: self = .unsupported(code: generalDecisionCode)
        }
    }
}

/// Decodes the `MediaContainer` returned by
/// `/video/:/transcode/universal/decision?hasMDE=1`, exposing the general decision and the
/// per-stream decisions ("copy" / "transcode" / "direct play") that say what PMS will
/// actually do to each stream — the reliable copy-vs-re-encode signal (research/09 §3.2,
/// research/15 §2.2). All of it is optional/defensive: servers omit pieces freely.
public struct DecisionResponse: Decodable, Sendable, Equatable {
    public let generalDecisionCode: Int?
    public let generalDecisionText: String?
    /// The Media Decision Engine's own decision code (`hasMDE=1`). On a direct-play probe
    /// PMS returns **1000 = direct play** here while leaving `generalDecisionCode` nil — the
    /// reliable structured direct-play signal (verified against live PMS, issue #7).
    public let mdeDecisionCode: Int?
    /// Free-text MDE explanation, e.g. "Convert to HLS, copy video, transcode audio" or
    /// "Direct play OK." — human-readable only; NEVER gate logic on this string.
    public let mdeDecisionText: String?
    /// Part-level `decision` of the first part ("directplay" / "copy" / "transcode"). PMS sets
    /// this on a full direct play and may leave the per-stream decisions nil, so it's a
    /// distinct copy-vs-re-encode signal from `videoDecision`.
    public let partDecision: String?
    /// Per-stream `decision` for the video stream (streamType 1) of the first part.
    public let videoDecision: String?
    /// Per-stream `decision` for the audio stream (streamType 2) of the first part.
    public let audioDecision: String?

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey {
        case generalDecisionCode
        case generalDecisionText
        case mdeDecisionCode
        case mdeDecisionText
        case metadata = "Metadata"
    }

    /// Minimal Metadata>Media>Part>Stream spine, decoded only for the `decision` attributes.
    private struct Metadata: Decodable { let Media: [Media]? }
    private struct Media: Decodable { let Part: [Part]? }
    private struct Part: Decodable { let decision: String?; let Stream: [Stream]? }
    private struct Stream: Decodable {
        let streamType: Int?
        let decision: String?
    }

    public init(generalDecisionCode: Int?, generalDecisionText: String?,
                mdeDecisionCode: Int? = nil,
                mdeDecisionText: String? = nil,
                partDecision: String? = nil,
                videoDecision: String? = nil, audioDecision: String? = nil) {
        self.generalDecisionCode = generalDecisionCode
        self.generalDecisionText = generalDecisionText
        self.mdeDecisionCode = mdeDecisionCode
        self.mdeDecisionText = mdeDecisionText
        self.partDecision = partDecision
        self.videoDecision = videoDecision
        self.audioDecision = audioDecision
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let container = try root.nestedContainer(keyedBy: ContainerKeys.self, forKey: .mediaContainer)
        self.generalDecisionCode = try container.decodeIfPresent(Int.self, forKey: .generalDecisionCode)
        self.generalDecisionText = try container.decodeIfPresent(String.self, forKey: .generalDecisionText)
        self.mdeDecisionCode = try container.decodeIfPresent(Int.self, forKey: .mdeDecisionCode)
        self.mdeDecisionText = try container.decodeIfPresent(String.self, forKey: .mdeDecisionText)
        let metadata = try container.decodeIfPresent([Metadata].self, forKey: .metadata)
        let part = metadata?.first?.Media?.first?.Part?.first
        self.partDecision = part?.decision
        let streams = part?.Stream ?? []
        self.videoDecision = streams.first { $0.streamType == 1 }?.decision
        self.audioDecision = streams.first { $0.streamType == 2 }?.decision
    }

    /// The interpreted decision. Falls back to `.unsupported(-1)` when PMS omits a code.
    public var decision: Decision {
        Decision(generalDecisionCode: generalDecisionCode ?? -1)
    }

    /// True when PMS will NOT re-encode video — i.e. the expensive software transcode is
    /// saved and the direct-play start URL is worth committing to (#7). PMS signals this three
    /// ways, and a probe may use only one of them, so we accept any:
    ///   1. `mdeDecisionCode == 1000` — whole-file direct play (per-stream decisions left nil),
    ///   2. Part-level `decision` is "copy"/"directplay" — remux or direct play of the part,
    ///   3. per-stream video `decision` is "copy"/"directplay" — Direct Stream (copy video,
    ///      transcode audio), where the part decision may read "transcode".
    /// Conservative: with none of these present, answer false (never claim a saved encode
    /// without evidence). Codes/enums only — never the English `mdeDecisionText`.
    public var savesVideoEncode: Bool {
        if mdeDecisionCode == 1000 { return true }            // direct play OK
        func isCopyOrDirect(_ s: String?) -> Bool {
            guard let v = s?.lowercased().replacingOccurrences(of: " ", with: "") else { return false }
            return v == "copy" || v == "directplay"
        }
        return isCopyOrDirect(partDecision) || isCopyOrDirect(videoDecision)
    }

    /// True ONLY when PMS will play the WHOLE file as-is (container + every stream), so the
    /// original file can be downloaded byte-for-byte for offline use (offline-download
    /// redesign). STRICTER than `savesVideoEncode`, which is also true for Direct Stream
    /// (copy video / transcode audio) and remux (part "copy") — neither of which yields a
    /// downloadable original file; those route to the Media Optimizer instead. Structured
    /// signals only, never the English `mdeDecisionText`:
    ///   1. `mdeDecisionCode == 1000` — MDE whole-file direct play, OR
    ///   2. `decision == .directPlay` (generalDecisionCode 1000), OR
    ///   3. Part-level `decision` (lowercased, spaces removed) == "directplay".
    /// A part/stream "copy" is deliberately NOT sufficient. Conservative: false without
    /// one of these signals.
    public var playsWholeFileDirectly: Bool {
        if mdeDecisionCode == 1000 { return true }
        if decision == .directPlay { return true }
        let normalizedPart = partDecision?.lowercased().replacingOccurrences(of: " ", with: "")
        return normalizedPart == "directplay"
    }
}
