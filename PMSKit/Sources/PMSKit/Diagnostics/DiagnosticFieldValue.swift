import Foundation

/// A single field value for a diagnostic event.
///
/// String-producing cases pass through `DiagnosticRedactor` before storage, so callers can
/// describe errors, labels and URL shapes without exporting tokens, hosts, paths or filenames.
/// Media titles and user/library names should still not be passed in the first place: the
/// diagnostics API is for reproduction facts and shape-level identifiers only.
public enum DiagnosticFieldValue: Codable, Equatable, Sendable, CustomStringConvertible {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public var description: String {
        switch self {
        case .string(let value): value
        case .int(let value): String(value)
        case .double(let value): Self.format(value)
        case .bool(let value): value ? "true" : "false"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }

    public static func text(_ value: String?) -> DiagnosticFieldValue {
        .string(DiagnosticRedactor.redact(value ?? "unknown"))
    }

    public static func label(_ value: String?) -> DiagnosticFieldValue {
        .string(DiagnosticRedactor.redact(value ?? "unknown"))
    }

    public static func urlShape(_ url: URL?) -> DiagnosticFieldValue {
        .string(DiagnosticRedactor.urlShape(url))
    }

    public static func error(_ error: Error?) -> DiagnosticFieldValue {
        .string(DiagnosticRedactor.safeErrorSummary(error))
    }

    public static func identifier(_ raw: String?) -> DiagnosticFieldValue {
        guard let raw, !raw.isEmpty else { return .string("id=unknown") }
        return .string("id=\(DiagnosticRedactor.stableIdentifier(for: raw))")
    }

    public static func bytes(_ bytes: Int?) -> DiagnosticFieldValue {
        guard let bytes, bytes >= 0 else { return .string("unknown") }
        return .string(DiagnosticRedactor.byteBucket(bytes))
    }

    public static func millisecondsBucket(_ milliseconds: Int?) -> DiagnosticFieldValue {
        guard let milliseconds, milliseconds > 0 else { return .string("0s") }
        let seconds = milliseconds / 1000
        switch seconds {
        case 0..<10: return .string("<10s")
        case 10..<60: return .string("\(seconds)s")
        case 60..<600: return .string("\(seconds / 60)m")
        default: return .string("\(seconds / 60)m+")
        }
    }

    public static func secondsBucket(_ seconds: Double?) -> DiagnosticFieldValue {
        guard let seconds, seconds.isFinite, seconds > 0 else { return .string("0s") }
        switch seconds {
        case 0..<10: return .string("<10s")
        case 10..<60: return .string("\(Int(seconds))s")
        case 60..<600: return .string("\(Int(seconds / 60))m")
        default: return .string("\(Int(seconds / 60))m+")
        }
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        return String(format: "%.2f", value)
    }
}
