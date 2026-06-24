import Foundation

/// Backend-agnostic, on-device summary of a single MetricKit diagnostic (crash, hang, CPU
/// exception, or disk-write exception).
///
/// MetricKit itself (`MXDiagnostic`/`MXMetricManager`) lives only in the app target; this type is
/// the pure, testable boundary in between. The app's thin glue lifts the fields it cares about off
/// the framework objects into a `MetricKitDiagnosticInput`, and this file turns that into a short,
/// **redacted** report fragment that fits the existing opt-in feedback path. Every string that
/// could carry a path/symbol/identifier passes through `DiagnosticRedactor.redact` before storage,
/// so a crash/hang becomes anonymous context in a user-sent report — no device IDs, no upload.
public enum MetricKitDiagnosticKind: String, Codable, Sendable, Equatable, CaseIterable {
    case crash = "Crash"
    case hang = "Hang"
    case cpuException = "CPU exception"
    case diskWriteException = "Disk-write exception"

    public init?(rawValue: String) {
        switch rawValue {
        case "Crash": self = .crash
        case "Hang": self = .hang
        case "CPU exception": self = .cpuException
        case "Disk-write exception": self = .diskWriteException
        default: return nil
        }
    }
}

/// The fields the app glue lifts off a MetricKit diagnostic before any of MetricKit's framework
/// types reach PMSKit. All strings are raw here; they are redacted when the summary is rendered.
public struct MetricKitDiagnosticInput: Sendable, Equatable {
    public var kind: MetricKitDiagnosticKind
    /// MetricKit's payload timestamp (end of the collection window the diagnostic came from).
    public var date: Date?
    /// Mach exception type, e.g. "EXC_BAD_ACCESS" — present on crashes.
    public var exceptionType: String?
    /// Mach exception code.
    public var exceptionCode: String?
    /// Unix signal name/number, e.g. "SIGSEGV" — present on crashes.
    public var signal: String?
    /// Human-readable termination reason (may embed a bundle path / framework path → redacted).
    public var terminationReason: String?
    /// Objective-C uncaught-exception name, e.g. "NSInvalidArgumentException".
    public var virtualMemoryRegionInfo: String?
    /// Hang duration in seconds (hang diagnostics) — bucketed, never exact.
    public var hangDurationSeconds: Double?
    /// Crash-thread call stack as already-symbolicated frame strings, innermost first. Symbol
    /// names are kept (they are the actionable signal) but redacted for embedded paths.
    public var callStackFrames: [String]

    public init(kind: MetricKitDiagnosticKind,
                date: Date? = nil,
                exceptionType: String? = nil,
                exceptionCode: String? = nil,
                signal: String? = nil,
                terminationReason: String? = nil,
                virtualMemoryRegionInfo: String? = nil,
                hangDurationSeconds: Double? = nil,
                callStackFrames: [String] = []) {
        self.kind = kind
        self.date = date
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.signal = signal
        self.terminationReason = terminationReason
        self.virtualMemoryRegionInfo = virtualMemoryRegionInfo
        self.hangDurationSeconds = hangDurationSeconds
        self.callStackFrames = callStackFrames
    }
}

/// A persisted, already-redacted summary of one diagnostic. This is the only MetricKit-derived
/// state the app keeps; it is plain `Codable` so the app can store the most-recent few in
/// `UserDefaults` and fold them into the feedback report.
public struct MetricKitDiagnosticSummary: Codable, Sendable, Equatable {
    public let kind: MetricKitDiagnosticKind
    public let timestamp: Date
    /// Already redacted, e.g. "EXC_BAD_ACCESS (SIGSEGV)" or "hang ~10s".
    public let headline: String
    /// Already redacted top frames (symbol names only), innermost first, capped for length.
    public let topFrames: [String]

    public init(kind: MetricKitDiagnosticKind,
                timestamp: Date,
                headline: String,
                topFrames: [String]) {
        self.kind = kind
        self.timestamp = timestamp
        self.headline = headline
        self.topFrames = topFrames
    }
}

public enum MetricKitDiagnosticSummarizer {
    /// How many call-stack frames we keep. The crash signature lives near the top of the stack;
    /// keeping a handful is enough to triage without turning the report into a full backtrace.
    public static let maxFrames = 8

    /// Build a redacted summary from one diagnostic input. All text is run through
    /// `DiagnosticRedactor.redact` so embedded bundle paths / dylib paths / addresses-as-paths
    /// cannot escape, and the hang duration is bucketed rather than reported exactly.
    public static func summarize(_ input: MetricKitDiagnosticInput,
                                 generatedAt: Date = Date()) -> MetricKitDiagnosticSummary {
        MetricKitDiagnosticSummary(
            kind: input.kind,
            timestamp: input.date ?? generatedAt,
            headline: headline(for: input),
            topFrames: redactedFrames(input.callStackFrames)
        )
    }

    /// Render the single line + indented frames a summary contributes to the diagnostic report.
    public static func reportLines(for summary: MetricKitDiagnosticSummary) -> [String] {
        let iso = ISO8601DateFormatter()
        var lines = ["- \(summary.kind.rawValue) at \(iso.string(from: summary.timestamp)): \(summary.headline)"]
        for frame in summary.topFrames {
            lines.append("    \(frame)")
        }
        return lines
    }

    /// Render the "Recent crashes/hangs (MetricKit)" section that folds into the feedback report.
    /// Empty array → a single "(none captured…)" line so the section is self-explanatory.
    public static func reportSection(for summaries: [MetricKitDiagnosticSummary]) -> [String] {
        var lines = ["Recent crashes/hangs (MetricKit, redacted, on-device)"]
        guard !summaries.isEmpty else {
            lines.append("- None captured since install.")
            return lines
        }
        for summary in summaries {
            lines.append(contentsOf: reportLines(for: summary))
        }
        return lines
    }

    private static func headline(for input: MetricKitDiagnosticInput) -> String {
        switch input.kind {
        case .crash:
            var parts: [String] = []
            if let type = nonEmptyRedacted(input.exceptionType) { parts.append(type) }
            if let signal = nonEmptyRedacted(input.signal) { parts.append("(\(signal))") }
            if let code = nonEmptyRedacted(input.exceptionCode) { parts.append("code \(code)") }
            if let reason = nonEmptyRedacted(input.terminationReason) { parts.append(reason) }
            if let region = nonEmptyRedacted(input.virtualMemoryRegionInfo) { parts.append(region) }
            return parts.isEmpty ? "crash (no exception detail)" : parts.joined(separator: " ")
        case .hang:
            return "hang \(durationBucket(input.hangDurationSeconds))"
        case .cpuException:
            return "CPU exception"
        case .diskWriteException:
            return "disk-write exception"
        }
    }

    /// Coarse hang bucket — exact durations are not interesting and avoid implying precision.
    private static func durationBucket(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds > 0 else { return "(unknown duration)" }
        switch seconds {
        case 0..<2: return "~<2s"
        case 2..<5: return "~2-5s"
        case 5..<10: return "~5-10s"
        case 10..<30: return "~10-30s"
        default: return "~30s+"
        }
    }

    private static func redactedFrames(_ frames: [String]) -> [String] {
        frames.prefix(maxFrames).compactMap { nonEmptyRedacted($0) }
    }

    private static func nonEmptyRedacted(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let redacted = DiagnosticRedactor.redact(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        return redacted.isEmpty ? nil : redacted
    }
}
