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
/// `/video/:/transcode/universal/decision?hasMDE=1`, exposing the general decision.
public struct DecisionResponse: Decodable, Sendable, Equatable {
    public let generalDecisionCode: Int?
    public let generalDecisionText: String?

    enum RootKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    enum ContainerKeys: String, CodingKey {
        case generalDecisionCode
        case generalDecisionText
    }

    public init(generalDecisionCode: Int?, generalDecisionText: String?) {
        self.generalDecisionCode = generalDecisionCode
        self.generalDecisionText = generalDecisionText
    }

    public init(from decoder: Decoder) throws {
        let root = try decoder.container(keyedBy: RootKeys.self)
        let container = try root.nestedContainer(keyedBy: ContainerKeys.self, forKey: .mediaContainer)
        self.generalDecisionCode = try container.decodeIfPresent(Int.self, forKey: .generalDecisionCode)
        self.generalDecisionText = try container.decodeIfPresent(String.self, forKey: .generalDecisionText)
    }

    /// The interpreted decision. Falls back to `.unsupported(-1)` when PMS omits a code.
    public var decision: Decision {
        Decision(generalDecisionCode: generalDecisionCode ?? -1)
    }
}
