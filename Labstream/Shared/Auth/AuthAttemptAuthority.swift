import Foundation

typealias AuthAttemptID = UUID

enum AuthOperation: Equatable {
    case plexPIN
    case jellyfinCredentials
    case jellyfinQuickConnect
    case embyCredentials
    case embyConnect
    case sessionRestore
    case downloadSessionHydration(MediaBackendKind)
}

/// The only mutable generation authority shared by all backend flow owners.
/// Backend-specific owners can perform work, but only this value admits publication.
struct AuthAttemptAuthority {
    private struct Attempt: Equatable {
        let id: AuthAttemptID
        let operation: AuthOperation
    }

    private var active: Attempt?

    var isIdle: Bool { active == nil }

    mutating func begin(_ operation: AuthOperation) -> AuthAttemptID {
        let attempt = Attempt(id: UUID(), operation: operation)
        active = attempt
        return attempt.id
    }

    func isCurrent(_ id: AuthAttemptID, taskIsCancelled: Bool) -> Bool {
        active?.id == id && !taskIsCancelled
    }

    func currentID(for operation: AuthOperation) -> AuthAttemptID? {
        guard active?.operation == operation else { return nil }
        return active?.id
    }

    mutating func finish(_ id: AuthAttemptID) {
        guard active?.id == id else { return }
        active = nil
    }

    mutating func cancel(_ id: AuthAttemptID) -> Bool {
        guard active?.id == id else { return false }
        active = nil
        return true
    }

    mutating func cancelAll() { active = nil }
}

/// Pure admission policy for session hydration. Launch restores exactly the selected
/// backend. An inactive lane is eligible only when download orchestration explicitly
/// asks for that backend, and tvOS never admits download-owned hydration.
enum AuthBackendHydrationPolicy {
    static func shouldHydrateInactiveBackend(_ requested: MediaBackendKind,
                                             selected: MediaBackendKind,
                                             downloadsAvailable: Bool) -> Bool {
        downloadsAvailable && requested != selected
    }
}
