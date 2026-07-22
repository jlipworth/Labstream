import Foundation

/// Owns the one credential-authorization polling task and its attempt-scoped metadata.
///
/// `AuthManager` still owns admission and publication through `AuthAttemptAuthority`; this
/// coordinator owns only task lifetime. Exact-owner finish/cancel operations prevent a stale
/// Plex, Jellyfin, or Emby poll from clearing a replacement backend's task.
@MainActor
struct AuthorizationPollingCoordinator {
    private var ownerID: AuthAttemptID?
    private var task: Task<Void, Never>?
    private var plexPINIDs: Set<Int> = []

    var isIdle: Bool { ownerID == nil }

    mutating func install(ownerID: AuthAttemptID,
                          plexPINIDs: Set<Int> = [],
                          task: Task<Void, Never>) {
        cancelAll()
        self.ownerID = ownerID
        self.plexPINIDs = plexPINIDs
        self.task = task
    }

    func ownsPlexPINs(_ pinIDs: Set<Int>, ownerID: AuthAttemptID) -> Bool {
        self.ownerID == ownerID && plexPINIDs == pinIDs
    }

    /// Release completed polling state only when the exact attempt still owns it.
    @discardableResult
    mutating func finish(ownerID: AuthAttemptID) -> Bool {
        guard self.ownerID == ownerID else { return false }
        self.ownerID = nil
        plexPINIDs = []
        task = nil
        return true
    }

    /// Cancel only the exact attempt's task; a stale cleanup cannot cancel its replacement.
    @discardableResult
    mutating func cancel(ownerID: AuthAttemptID) -> Bool {
        guard self.ownerID == ownerID else { return false }
        task?.cancel()
        self.ownerID = nil
        plexPINIDs = []
        task = nil
        return true
    }

    mutating func cancelAll() {
        task?.cancel()
        ownerID = nil
        plexPINIDs = []
        task = nil
    }
}
