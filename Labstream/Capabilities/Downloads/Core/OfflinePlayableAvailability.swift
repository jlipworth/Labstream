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
