import Foundation
import os
import PMSKit

#if os(tvOS)
/// MetricKit's crash/diagnostic subscriber API is unavailable on tvOS. Preserve the
/// diagnostics-report boundary with an empty provider until a TV-native channel exists.
final class MetricKitDiagnostics: @unchecked Sendable {
    static let shared = MetricKitDiagnostics()

    func register() {}
    func storedSummaries() -> [MetricKitDiagnosticSummary] { [] }
}
#else
import MetricKit

/// Passive crash/hang channel (#116).
///
/// Adopts `MXMetricManager` so the OS hands us crash / hang / CPU / disk-write diagnostics after a
/// bad run. We lift the actionable fields off MetricKit's framework objects, hand them to PMSKit's
/// pure `MetricKitDiagnosticSummarizer` (which redacts everything), and persist a bounded list of
/// the resulting anonymous summaries. They surface ONLY through the existing user-initiated
/// feedback path: `AppDiagnostics.report(...)` folds the most-recent few into the report the
/// feedback sheet already previews/shares. Nothing is uploaded; no device IDs, email, or IPs.
///
/// Regular `MXMetricPayload`s (performance histograms) are not used — we keep just the diagnostic
/// track this issue is about. MetricKit delivers on a background queue, so the store is locked.
final class MetricKitDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitDiagnostics()

    /// How many recent summaries we keep / fold into a report. A crash report only needs the last
    /// few; the cap also bounds the persisted blob.
    static let maxStored = 5
    private static let defaultsKey = "metricKitDiagnosticSummaries"

    private let logger = Logger(subsystem: "org.labstream.Labstream", category: "Diagnostics")
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        super.init()
    }

    /// Register at launch. Idempotent enough for our single call site; `add(_:)` simply (re)adds
    /// this subscriber. After registration MetricKit will deliver any diagnostics queued from the
    /// previous (crashed) run on its next callback.
    func register() {
        MXMetricManager.shared.add(self)
    }

    /// The redacted summaries, newest last, for folding into the feedback report.
    func storedSummaries() -> [MetricKitDiagnosticSummary] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    // MARK: MXMetricManagerSubscriber

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Performance metric histograms are out of scope for the crash/hang channel (#116).
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let inputs = payloads.flatMap(Self.inputs(from:))
        guard !inputs.isEmpty else { return }
        let newSummaries = inputs.map { MetricKitDiagnosticSummarizer.summarize($0) }

        lock.lock()
        var stored = loadLocked()
        stored.append(contentsOf: newSummaries)
        if stored.count > Self.maxStored {
            stored.removeFirst(stored.count - Self.maxStored)
        }
        saveLocked(stored)
        lock.unlock()

        // Already-redacted headline; %@ guards any stray %.
        for summary in newSummaries {
            logger.notice("MetricKit diagnostic: \(summary.kind.rawValue, privacy: .public) \(summary.headline, privacy: .public)")
        }
    }

    // MARK: Persistence (caller holds `lock`)

    private func loadLocked() -> [MetricKitDiagnosticSummary] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder.iso8601.decode([MetricKitDiagnosticSummary].self, from: data) else {
            return []
        }
        return decoded
    }

    private func saveLocked(_ summaries: [MetricKitDiagnosticSummary]) {
        guard let data = try? JSONEncoder.iso8601.encode(summaries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    // MARK: MetricKit → pure input

    /// Lift the fields we care about off each diagnostic in a payload. Crash and hang are the
    /// channels with real signal; CPU/disk-write are recorded as bare typed events so they still
    /// show up in a report. Raw strings here — `MetricKitDiagnosticSummarizer` redacts them.
    static func inputs(from payload: MXDiagnosticPayload) -> [MetricKitDiagnosticInput] {
        var inputs: [MetricKitDiagnosticInput] = []
        let date = payload.timeStampEnd

        for crash in payload.crashDiagnostics ?? [] {
            inputs.append(MetricKitDiagnosticInput(
                kind: .crash,
                date: date,
                exceptionType: crash.exceptionType.map { "EXC \($0)" },
                exceptionCode: crash.exceptionCode?.stringValue,
                signal: crash.signal.map { "signal \($0)" },
                terminationReason: crash.terminationReason,
                virtualMemoryRegionInfo: crash.virtualMemoryRegionInfo,
                callStackFrames: stack(from: crash.callStackTree).frames,
                appBinaryUUID: stack(from: crash.callStackTree).appBinaryUUID
            ))
        }

        for hang in payload.hangDiagnostics ?? [] {
            inputs.append(MetricKitDiagnosticInput(
                kind: .hang,
                date: date,
                hangDurationSeconds: hang.hangDuration.converted(to: .seconds).value,
                callStackFrames: stack(from: hang.callStackTree).frames,
                appBinaryUUID: stack(from: hang.callStackTree).appBinaryUUID
            ))
        }

        for _ in payload.cpuExceptionDiagnostics ?? [] {
            inputs.append(MetricKitDiagnosticInput(kind: .cpuException, date: date))
        }

        for _ in payload.diskWriteExceptionDiagnostics ?? [] {
            inputs.append(MetricKitDiagnosticInput(kind: .diskWriteException, date: date))
        }

        return inputs
    }

    /// The app executable's name, as MetricKit reports it in `binaryName`.
    private static let appBinaryName = Bundle.main.executableURL?.lastPathComponent

    private static func stack(from tree: MXCallStackTree) -> MetricKitCallStackParser.Stack {
        MetricKitCallStackParser.stack(fromJSON: tree.jsonRepresentation(), appBinaryName: appBinaryName)
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
#endif
