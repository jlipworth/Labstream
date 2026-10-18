#if !os(tvOS)
import Foundation

/// Readability and mutation admission are independent. A readable blocked store can play terminal
/// rows with its recovery banner and mutations disabled. Opaque indices cannot open Offline.
enum OfflinePlayableIndexAccess: Equatable, Sendable {
    case readable
    case admissionBlockedReadable
    case unreadable
    case unsupported
}

/// Ephemeral result of an off-MainActor scan of exact terminal (attempt, URL) candidates. Publish
/// only if `generation` still matches; empty candidates withdraw availability immediately.
/// Unchanged candidates/progress/body reads must not stat again. Foreground and terminal/replace/
/// Delete/reset/recovery edges refresh; availability never grants auth or replaces Play admission.
struct OfflinePlayableAvailability: Equatable, Sendable {
    enum Scan: Equatable, Sendable {
        case unresolved
        case resolved(hasPlayableFile: Bool)
    }
    let generation: UInt64
    let indexAccess: OfflinePlayableIndexAccess
    let scan: Scan
}
#endif

#if !os(tvOS)
import Observation
import PMSKit

@Observable @MainActor
final class OfflinePlayableAvailabilityCache {
    struct Candidate: Equatable, Sendable {
        let key: DownloadAttemptKey
        let url: URL
        // A promotion/publication is a refresh edge even when the exact path is unchanged.
        let terminalStatus: DownloadStatus
    }
    private(set) var value = OfflinePlayableAvailability(generation: 0, indexAccess: .readable, scan: .unresolved)
    @ObservationIgnored private var candidates: [Candidate] = []
    @ObservationIgnored private(set) var worker: Task<Void, Never>?

    var hasPlayableFile: Bool {
        guard value.indexAccess == .readable || value.indexAccess == .admissionBlockedReadable else { return false }
        return value.scan == .resolved(hasPlayableFile: true)
    }

    func refresh(records: [DownloadRecord], access: OfflinePlayableIndexAccess,
                 force: Bool = false, fileExists: @escaping @Sendable (URL) -> Bool) {
        let next = records.filter(\.isComplete).compactMap { row -> Candidate? in
            guard let attemptID = row.attemptID else { return nil }
            return .init(key: .init(ratingKey: row.ratingKey, attemptID: attemptID),
                         url: row.localURL, terminalStatus: row.status)
        }.sorted { $0.key.ratingKey < $1.key.ratingKey }
        guard next != candidates || access != value.indexAccess || (force && worker == nil)
                || value.scan == .unresolved && worker == nil else { return }
        candidates = next
        let generation = value.generation &+ 1
        worker?.cancel()
        value = .init(generation: generation, indexAccess: access,
                      scan: next.isEmpty || access == .unreadable || access == .unsupported
                        ? .resolved(hasPlayableFile: false) : .unresolved)
        guard value.scan == .unresolved else { worker = nil; return }
        worker = Task { @MainActor in
            let found = await Task.detached { next.contains { fileExists($0.url) } }.value
            guard value.generation == generation else { return }
            value = .init(generation: generation, indexAccess: access, scan: .resolved(hasPlayableFile: found))
            worker = nil
        }
    }
}
#endif
