import Foundation

/// IO-free identity for download ENTRY-POINT start attempts.
///
/// The backend entry points (`download`, `downloadJellyfin`, `downloadEmby`) all contain long
/// negotiation awaits (PlaybackInfo POSTs, the Plex `.original` AVPlayer preflight) BETWEEN
/// acquiring the per-key in-flight slot and the first store write / `session.start`. A delete or
/// pause landing during such an await releases the slot and removes/parks the row — but the
/// resumed chain used to re-seed the row and start the transfer anyway, resurrecting a deleted
/// download with a live server encoder.
///
/// This tracker mints one UUID per accepted start; the coordinator clears it whenever the
/// in-flight slot is released (terminal transition, pause, delete) and re-mints on the next
/// accepted start. A chain that captured its token at acquisition can therefore detect, after
/// every await, that it has been superseded — even when the same key has since been re-downloaded
/// (which re-populates `activeJobs` but with a NEW token).
public struct DownloadStartAttemptTracker: Sendable, Equatable {
    private var attemptByKey: [String: UUID] = [:]

    public init() {}

    /// Mint (or replace) the current start-attempt token for `recordKey`.
    @discardableResult
    public mutating func begin(_ recordKey: String, id: UUID = UUID()) -> UUID {
        attemptByKey[recordKey] = id
        return id
    }

    /// Whether `id` is still the live attempt for `recordKey`.
    public func isCurrent(_ recordKey: String, id: UUID) -> Bool {
        attemptByKey[recordKey] == id
    }

    /// Drop the current attempt (release/delete/pause). Any outstanding chain holding the old
    /// token becomes stale immediately.
    @discardableResult
    public mutating func clear(_ recordKey: String) -> Bool {
        attemptByKey.removeValue(forKey: recordKey) != nil
    }
}

/// Pure decision for the post-await entry-point currency check.
///
/// A start chain may only proceed to a store write or `session.start` when:
///   token current ∧ in-flight slot still held ∧ (if it entered with an existing row) that row is
///   still present ∧ the row (if any) has not been parked `.paused` in the meantime.
///
/// On any failure the chain must exit WITHOUT upserting — notably it must NOT clobber a row a
/// pause parked `.paused` back to `.queued`, and must not re-seed a row a delete removed.
public enum DownloadStartGuardPolicy {
    public enum Reason: String, Sendable, Equatable {
        /// A newer start attempt replaced this chain's token (delete→re-download, retry churn).
        case tokenSuperseded = "token_superseded"
        /// The in-flight slot was released (delete, pause, terminal sweep) and not re-minted.
        case slotReleased = "slot_released"
        /// The chain entered with a visible row that has since been removed.
        case rowRemoved = "row_removed"
        /// The row was parked `.paused` during the await (user pause / queue-pause parking);
        /// proceeding would clobber it back to an active status.
        case rowPaused = "row_paused"
    }

    public enum Verdict: Sendable, Equatable {
        case proceed
        case superseded(reason: Reason)
    }

    public static func verdict(tokenIsCurrent: Bool,
                               hasActiveSlot: Bool,
                               enteredWithExistingRow: Bool,
                               rowIsPresent: Bool,
                               rowStatus: DownloadStatus?) -> Verdict {
        guard tokenIsCurrent else { return .superseded(reason: .tokenSuperseded) }
        guard hasActiveSlot else { return .superseded(reason: .slotReleased) }
        if enteredWithExistingRow, !rowIsPresent {
            return .superseded(reason: .rowRemoved)
        }
        if rowStatus == .paused {
            return .superseded(reason: .rowPaused)
        }
        return .proceed
    }
}
