#if DEBUG || PERFORMANCE_AUDIT
import Foundation
import os

/// Lightweight, privacy-preserving performance instrumentation for Debug and PerformanceAudit.
///
/// The signpost names are intentionally generic and stable so Instruments' Points of
/// Interest can compare Plex vs. Jellyfin runs without exposing library titles, server
/// URLs, account names, tokens, client identifiers, or local paths.
enum PerformanceInstrumentation {
    enum Phase: String {
        case runtimeComposition = "runtime.composition"
        case sessionRestore = "session.restore"
        case homeLoad = "home.load"
        case librariesLoad = "libraries.load"
        case libraryGridInitialPage = "library_grid.initial_page"
        case libraryGridPage = "library_grid.page"
        case detailMetadata = "detail.metadata"
        case playbackResolve = "playback.resolve"
        case playbackStartup = "playback.startup"
        case playbackItemLoad = "playback.item_load"
        case artworkLoad = "artwork.load"

        var signpostName: StaticString {
            switch self {
            case .runtimeComposition: return "runtime.composition"
            case .sessionRestore: return "session.restore"
            case .homeLoad: return "home.load"
            case .librariesLoad: return "libraries.load"
            case .libraryGridInitialPage: return "library_grid.initial_page"
            case .libraryGridPage: return "library_grid.page"
            case .detailMetadata: return "detail.metadata"
            case .playbackResolve: return "playback.resolve"
            case .playbackStartup: return "playback.startup"
            case .playbackItemLoad: return "playback.item_load"
            case .artworkLoad: return "artwork.load"
            }
        }

        var osLog: OSLog {
            switch self {
            case .runtimeComposition, .sessionRestore:
                return Self.launchLog
            case .homeLoad:
                return Self.homeLog
            case .librariesLoad, .libraryGridInitialPage, .libraryGridPage, .detailMetadata:
                return Self.libraryLog
            case .playbackResolve, .playbackStartup, .playbackItemLoad:
                return Self.playbackLog
            case .artworkLoad:
                return Self.artworkLog
            }
        }

        private static let launchLog = OSLog(subsystem: PerformanceInstrumentation.subsystem,
                                             category: "Launch")
        private static let homeLog = OSLog(subsystem: PerformanceInstrumentation.subsystem,
                                           category: "Home")
        private static let libraryLog = OSLog(subsystem: PerformanceInstrumentation.subsystem,
                                              category: "LibraryGrid")
        private static let playbackLog = OSLog(subsystem: PerformanceInstrumentation.subsystem,
                                               category: "Playback")
        private static let artworkLog = OSLog(subsystem: PerformanceInstrumentation.subsystem,
                                              category: "Artwork")
    }

    static let subsystem = "com.jlipworth.Labstream"
    private static let logger = Logger(subsystem: subsystem, category: "Performance")

    static func begin(_ phase: Phase,
                      backend: String,
                      fields: @autoclosure () -> [String: Any] = [:]) -> PerformanceSpan {
        let log = phase.osLog
        let signpostID = OSSignpostID(log: log)
        let formattedFields = format(fields())
        os_signpost(.begin, log: log, name: phase.signpostName, signpostID: signpostID)
        logger.debug("perf.begin phase=\(phase.rawValue, privacy: .public) backend=\(sanitize(backend), privacy: .public) \(formattedFields, privacy: .public)")
        return PerformanceSpan(phase: phase,
                               backend: sanitize(backend),
                               log: log,
                               signpostID: signpostID,
                               startedAt: CFAbsoluteTimeGetCurrent())
    }

    static func span(_ phase: Phase,
                     backend: String,
                     fields: @autoclosure () -> [String: Any] = [:],
                     operation: () async throws -> Void) async rethrows {
        let span = begin(phase, backend: backend, fields: fields())
        do {
            try await operation()
            span.end()
        } catch {
            span.end(result: "failure", fields: ["error": errorLabel(error)])
            throw error
        }
    }

    static func logEnd(_ span: PerformanceSpan,
                       result: String,
                       durationMs: Int,
                       fields: [String: Any]) {
        logger.info("perf.span phase=\(span.phase.rawValue, privacy: .public) backend=\(span.backend, privacy: .public) result=\(sanitize(result), privacy: .public) duration_ms=\(durationMs, privacy: .public) \(format(fields), privacy: .public)")
    }

    static func errorLabel(_ error: Error) -> String {
        let raw = String(describing: type(of: error))
        return raw.isEmpty ? "error" : sanitize(raw)
    }

    static func sanitize(_ value: String) -> String {
        var output = ""
        output.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 48...57, 65...90, 97...122: // 0-9 A-Z a-z
                output.unicodeScalars.append(scalar)
            case 45, 46, 58, 95: // - . : _
                output.unicodeScalars.append(scalar)
            default:
                output.append("_")
            }
        }
        return output.isEmpty ? "none" : output
    }

    private static func format(_ fields: [String: Any]) -> String {
        fields
            .sorted { $0.key < $1.key }
            .map { "\(sanitize($0.key))=\(sanitize(String(describing: $0.value)))" }
            .joined(separator: " ")
    }
}

/// One shared gate follows a span across value copies and makes its terminal event atomic.
/// Claiming before formatting the terminal fields also prevents duplicate callers from doing
/// privacy-sensitive/logging work after another caller has already ended the span.
final class PerformanceSpanEndGate: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !ended else { return false }
        ended = true
        return true
    }
}

struct PerformanceSpan {
    let phase: PerformanceInstrumentation.Phase
    let backend: String
    let log: OSLog
    let signpostID: OSSignpostID
    let startedAt: CFAbsoluteTime
    private let endGate = PerformanceSpanEndGate()

    func end(result: String = "success",
             fields: @autoclosure () -> [String: Any] = [:]) {
        guard endGate.claim() else { return }
        let durationMs = max(0, Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0))
        os_signpost(.end, log: log, name: phase.signpostName, signpostID: signpostID)
        PerformanceInstrumentation.logEnd(self,
                                          result: result,
                                          durationMs: durationMs,
                                          fields: fields())
    }
}

extension MediaBackendKind {
    var performanceLabel: String { displayName }
}
#else

import Foundation

/// No-op performance instrumentation outside Debug and PerformanceAudit builds so release/user apps do not
/// emit profiling logs or pay signpost/logging overhead.
enum PerformanceInstrumentation {
    enum Phase: String {
        case runtimeComposition = "runtime.composition"
        case sessionRestore = "session.restore"
        case homeLoad = "home.load"
        case librariesLoad = "libraries.load"
        case libraryGridInitialPage = "library_grid.initial_page"
        case libraryGridPage = "library_grid.page"
        case detailMetadata = "detail.metadata"
        case playbackResolve = "playback.resolve"
        case playbackStartup = "playback.startup"
        case playbackItemLoad = "playback.item_load"
        case artworkLoad = "artwork.load"
    }

    static func begin(_ phase: Phase,
                      backend: String,
                      fields: @autoclosure () -> [String: Any] = [:]) -> PerformanceSpan {
        PerformanceSpan()
    }

    static func span(_ phase: Phase,
                     backend: String,
                     fields: @autoclosure () -> [String: Any] = [:],
                     operation: () async throws -> Void) async rethrows {
        try await operation()
    }

    static func errorLabel(_ error: Error) -> String { "error" }
}

struct PerformanceSpan {
    func end(result: String = "success", fields: @autoclosure () -> [String: Any] = [:]) {}
}

extension MediaBackendKind {
    var performanceLabel: String { displayName }
}

#endif
