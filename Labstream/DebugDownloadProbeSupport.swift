#if DEBUG
import Foundation

/// #135 Stage 8: shared scaffolding for the three launch-arg download probes
/// (`DebugPlexDownloadProbe` / `DebugEmbyDownloadProbe` / `DebugJellyfinDownloadProbe`).
///
/// Each probe previously carried its own byte-identical copies of the launch-arg parsers and the
/// download-record snapshot type/reader. Those are pure, backend-agnostic primitives, so they live
/// here once. The per-probe `observe` loops stay in their own files — they log to distinct
/// diagnostic categories and differ in shape (Plex carries a `label` + `.done` record), which is
/// real per-probe nuance, not duplication.
enum DebugDownloadProbeSupport {

    /// Snapshot of a download record's transfer state, as the probes log/assert on it. `status` is
    /// the `DownloadStatus` description, or `"missing"` when no row exists for the key yet.
    struct Observation {
        let progress: Double
        let bytes: Int
        let status: String
    }

    /// Read the current `Observation` for a record key off the live manager (`.records` is
    /// `@MainActor`-isolated, so this is too).
    @MainActor
    static func observation(forRecordKey recordKey: String, in manager: DownloadManager) -> Observation {
        let record = manager.records.first { $0.ratingKey == recordKey }
        return Observation(progress: record?.progress ?? 0,
                           bytes: record?.bytes ?? 0,
                           status: record.map { String(describing: $0.status) } ?? "missing")
    }

    /// The argument immediately following `flag`, or nil if `flag` is absent or last.
    static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// `value(after:in:)` parsed as an `Int`, or nil.
    static func intValue(after flag: String, in arguments: [String]) -> Int? {
        value(after: flag, in: arguments).flatMap(Int.init)
    }
}
#endif
