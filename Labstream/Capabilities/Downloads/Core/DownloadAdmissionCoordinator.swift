import Foundation
import PMSKit

/// The in-memory half of the one admission window (downloads overhaul P4.2).
///
/// Lane occupancy is not owned here: the manager observes it from persisted lifecycle plus live
/// work, so pause, failure, finalizing and delete free a lane without any release call. This type
/// holds only what persistence cannot: a supervised start per row (spawned but not yet proven,
/// fenced by a generation so a stale continuation can never settle its successor), request
/// ordering and backoff, and the row-scoped pause exemptions. Waiting requests themselves are
/// durable rows (`planned`, or paused/failed with a `retryRequested` intent).
@MainActor
final class DownloadAdmissionCoordinator {
    struct Supervision: Equatable {
        let generation: UUID
        var lane: DownloadAdmissionLane
        let origin: DownloadAdmissionOrigin
    }

    struct RequestState: Equatable {
        var origin: DownloadAdmissionOrigin
        var requestedAt: TimeInterval
        var eligibleAt: TimeInterval
        var deferrals: Int
    }

    private(set) var supervised: [String: Supervision] = [:]
    private(set) var requestStates: [String: RequestState] = [:]
    private(set) var pauseExemptions: Set<String> = []
    /// Startup recovery has reattached tasks and pollers; nothing is granted before (P4.2).
    var recoveryComplete = false
    /// Injectable clock for backoff (tests drive it).
    var now: () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }

    /// Record (or refresh the origin of) a waiting request. An explicit user request upgrades an
    /// automatic one and becomes eligible immediately; a repeated request keeps its place.
    func noteRequest(_ id: String, origin: DownloadAdmissionOrigin) {
        let time = now()
        if var existing = requestStates[id] {
            if origin < existing.origin {
                existing.origin = origin
                existing.eligibleAt = time
                existing.deferrals = 0
            }
            requestStates[id] = existing
        } else {
            requestStates[id] = RequestState(origin: origin, requestedAt: time,
                                             eligibleAt: time, deferrals: 0)
        }
    }

    /// The policy view of a waiting row. Rows found after a relaunch have no in-memory state and
    /// are automatic, oldest first.
    func request(for id: String, lane: DownloadAdmissionLane) -> DownloadAdmissionRequest {
        let state = requestStates[id]
        return DownloadAdmissionRequest(id: id, lane: lane,
                                        origin: state?.origin ?? .automatic,
                                        requestedAt: state?.requestedAt ?? 0,
                                        eligibleAt: state?.eligibleAt ?? 0)
    }

    func beginSupervision(_ id: String, lane: DownloadAdmissionLane,
                          origin: DownloadAdmissionOrigin) -> UUID {
        let generation = UUID()
        supervised[id] = Supervision(generation: generation, lane: lane, origin: origin)
        return generation
    }

    /// Ends a supervised start. False when the generation was superseded or invalidated (pause,
    /// delete, a newer start): the caller must not touch the row.
    @discardableResult
    func endSupervision(_ id: String, generation: UUID) -> Bool {
        guard supervised[id]?.generation == generation else { return false }
        supervised[id] = nil
        return true
    }

    func isCurrent(_ id: String, generation: UUID) -> Bool {
        supervised[id]?.generation == generation
    }

    /// P4.5: move a supervised start into another lane before it creates server or encoder work.
    @discardableResult
    func switchLane(_ id: String, generation: UUID, to lane: DownloadAdmissionLane) -> Bool {
        guard supervised[id]?.generation == generation else { return false }
        supervised[id]?.lane = lane
        return true
    }

    /// Pause and delete invalidate a row's supervised start and forget its request.
    func invalidate(_ id: String) {
        supervised[id] = nil
        requestStates[id] = nil
    }

    func clearRequest(_ id: String) {
        requestStates[id] = nil
    }

    /// A deferred start (backend unavailable) waits with capped backoff before it is eligible.
    func recordDeferral(_ id: String) {
        let time = now()
        var state = requestStates[id]
            ?? RequestState(origin: .automatic, requestedAt: time, eligibleAt: time, deferrals: 0)
        state.eligibleAt = time + DownloadAdmissionPolicy.deferralDelay(afterAttempt: state.deferrals)
        state.deferrals += 1
        requestStates[id] = state
    }

    func exempt(_ id: String) { pauseExemptions.insert(id) }
    func revokeExemption(_ id: String) { pauseExemptions.remove(id) }
    func revokeAllExemptions() { pauseExemptions.removeAll() }
    func isExempt(_ id: String) -> Bool { pauseExemptions.contains(id) }
}
