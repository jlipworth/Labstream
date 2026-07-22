import Foundation

/// The persistence guarantee required by a piece of app state.
///
/// Download index and cleanup ownership remain on their existing exact commit/barrier path. This
/// vocabulary prevents less-authoritative state (preferences and diagnostics) from accidentally
/// being treated as if it had the same contract.
enum PersistenceDurabilityTier: String, CaseIterable, Sendable {
    /// The caller cannot release an external lifecycle token until the write is committed.
    case barrier
    /// A coalesced checkpoint may be replayed after interruption without changing authority.
    case recoverableCheckpoint
    /// Bounded loss is acceptable; flush at lifecycle boundaries when practical.
    case bestEffort
    /// Process-local state that is never recovery authority.
    case ephemeral
}
