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
    /// Free-text MDE explanation, e.g. "Convert to HLS, copy video, transcode audio".
    public let mdeDecisionText: String?
    /// Per-stream `decision` for the video stream (streamType 1) of the first part.
    public let videoDecision: String?
    /// Per-stream `decision` for the audio stream (streamType 2) of the first part.
    public let audioDecision: String?

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey {
        case generalDecisionCode
        case generalDecisionText
        case mdeDecisionText
        case metadata = "Metadata"
    }

    /// Minimal Metadata>Media>Part>Stream spine, decoded only for the `decision` attributes.
    private struct Metadata: Decodable { let Media: [Media]? }
    private struct Media: Decodable { let Part: [Part]? }
    private struct Part: Decodable { let Stream: [Stream]? }
    private struct Stream: Decodable {
        let streamType: Int?
        let decision: String?
    }

    public init(generalDecisionCode: Int?, generalDecisionText: String?,
                mdeDecisionText: String? = nil,
                videoDecision: String? = nil, audioDecision: String? = nil) {
        self.generalDecisionCode = generalDecisionCode
        self.generalDecisionText = generalDecisionText
        self.mdeDecisionText = mdeDecisionText
        self.videoDecision = videoDecision
        self.audioDecision = audioDecision
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let container = try root.nestedContainer(keyedBy: ContainerKeys.self, forKey: .mediaContainer)
        self.generalDecisionCode = try container.decodeIfPresent(Int.self, forKey: .generalDecisionCode)
        self.generalDecisionText = try container.decodeIfPresent(String.self, forKey: .generalDecisionText)
        self.mdeDecisionText = try container.decodeIfPresent(String.self, forKey: .mdeDecisionText)
        let metadata = try container.decodeIfPresent([Metadata].self, forKey: .metadata)
        let streams = metadata?.first?.Media?.first?.Part?.first?.Stream ?? []
        self.videoDecision = streams.first { $0.streamType == 1 }?.decision
        self.audioDecision = streams.first { $0.streamType == 2 }?.decision
    }

    /// The interpreted decision. Falls back to `.unsupported(-1)` when PMS omits a code.
    public var decision: Decision {
        Decision(generalDecisionCode: generalDecisionCode ?? -1)
    }

    /// True when PMS will NOT re-encode video — `videoDecision` is "copy" or
    /// "direct play"/"directplay" — i.e. the expensive software transcode is saved and the
    /// direct-play start URL is worth committing to. Conservative: an absent per-stream
    /// decision answers false (never claim a saved encode without evidence).
    public var savesVideoEncode: Bool {
        guard let v = videoDecision?.lowercased().replacingOccurrences(of: " ", with: "") else {
            return false
        }
        return v == "copy" || v == "directplay"
    }
}
