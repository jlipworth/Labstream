import Foundation
import PMSKit

/// P6.1 value contract, consumed by the P6.4 session/registry/coordinator implementation.
/// Receipt belongs to the registry, before MainActor session construction/registration.
struct DownloadWakeBudget: Sendable {
    static let application = Self(wholeWake: 25, operation: 20, persistenceReserve: 5)
    let wholeWake: TimeInterval
    let operation: TimeInterval
    let persistenceReserve: TimeInterval
}

/// Frozen at registry receipt, including when no session exists yet. Registration/replay must
/// preserve these instants; session construction and later same-wake handlers cannot slide them.
struct DownloadWakeHandlerReceipt: Sendable, Equatable {
    let identifier: String
    let token: BackgroundDownloadCompletionHandlerToken
    let receivedAt: UInt64
    let absoluteDeadline: UInt64
}

struct DownloadWakeGeneration: Hashable, Sendable { let id: UUID }
struct DownloadWakeOperation: Equatable, Sendable {
    enum Kind: Sendable { case append, heldLifecycle, finalization, delayedRetry, grace }
    let id: UUID
    let wake: DownloadWakeGeneration?
    let startedAt: UInt64
    let kind: Kind
}

struct DownloadWakePersistenceBoundary: Sendable, Equatable {
    let index: DownloadStore.PersistenceTicket
    let artifacts: DownloadArtifactLifecycleCoordinator.Watermark
}

/// A cached proactive flush proves only its captured boundary. Normal release requires all three
/// conditions; expiry with unfinished work is timedOut even if that flush happened to commit.
struct DownloadWakeReleasePredicate: Sendable, Equatable {
    let finishEvents: Bool
    let requiredOperationsSettled: Bool
    let persistenceCoversResultingBoundary: Bool
    var permitsNormalRelease: Bool {
        finishEvents && requiredOperationsSettled && persistenceCoversResultingBoundary
    }
}

struct DownloadWakeTerminalAcknowledgement: Sendable, Equatable {
    enum Outcome: Sendable { case drained, timedOut, startupBlocked }
    let generation: DownloadWakeGeneration
    let outcome: Outcome
    let batches: [BackgroundDownloadCompletionReleaseBatch]
}

/// Scheduling acknowledgement is synchronous: tests advance only after observing registration.
/// Terminal acknowledgement means exact token claim/dispatch eligibility, not physical worker
/// cancellation or proof that MainActor has delivered callbacks. Expired workers retain leases.
struct DownloadWakeClockHooks: Sendable {
    struct Timer: Sendable, Equatable {
        enum Kind: Sendable { case operation, persistenceReserve, absoluteDeadline, grace }
        let id: UUID
        let deadline: UInt64
        let kind: Kind
    }
    let now: @Sendable () -> UInt64
    let register: @Sendable (Timer, @escaping @Sendable () -> Void) -> Void
    let terminalAcknowledged: @Sendable (DownloadWakeTerminalAcknowledgement) -> Void
}

enum DownloadStartupWakeState: Sendable, Equatable {
    case deferred
    case activating(generation: UInt64)
    case blockedBeforeTransport(generation: UInt64)
    case failedAfterTransport(generation: UInt64)
    case active(generation: UInt64)
}

extension DownloadWakeBudget {
    static func deadline(from instant: UInt64, after seconds: TimeInterval) -> UInt64 {
        let delta = UInt64(min(max(0, seconds.isFinite ? seconds : 0) * 1_000_000_000,
                               Double(UInt64.max - instant) / 2))
        return instant + delta
    }
}

extension DownloadWakeClockHooks {
    static let live = Self(
        now: { DispatchTime.now().uptimeNanoseconds },
        register: { timer, action in
            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: DispatchTime(uptimeNanoseconds: timer.deadline), execute: action)
        },
        terminalAcknowledged: { acknowledgement in
            AppDiagnostics.record(.downloads, "downloads.background_wake_terminal", fields: [
                "outcome": .label(acknowledgement.outcome.diagnosticLabel),
                "handler_count": .int(acknowledgement.batches.reduce(0) { $0 + $1.tokens.count }),
            ])
        })
}

extension DownloadStartupWakeState {
    var generation: UInt64? {
        switch self {
        case .deferred: nil
        case .activating(let value), .blockedBeforeTransport(let value),
             .failedAfterTransport(let value), .active(let value): value
        }
    }
    func supersedes(_ previous: Self?) -> Bool {
        guard let previous else { return true }
        if let old = previous.generation {
            guard let new = generation else { return false }
            return new >= old
        }
        return true
    }
}

extension DownloadWakeTerminalAcknowledgement.Outcome {
    var diagnosticLabel: String {
        switch self {
        case .drained: "drained"
        case .timedOut: "timed_out"
        case .startupBlocked: "startup_blocked"
        }
    }
}
