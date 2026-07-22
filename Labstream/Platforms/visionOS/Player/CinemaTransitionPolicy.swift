import PMSKit

/// Monotonic identity for one attempt to hand a player session into Cinema.
///
/// Every asynchronous immersive-space callback carries the generation it was started for. The
/// reducer ignores callbacks from older generations, preventing a late open/dismiss completion
/// from mutating a newer player session.
struct CinemaTransitionGeneration: RawRepresentable, Hashable, Comparable, Sendable {
    let rawValue: UInt64

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum CinemaEntryResult: Equatable, Sendable {
    case opened
    case userCancelled
    case failed
}

enum CinemaExitCause: Equatable, Sendable {
    case explicit
    case playbackEnded
    case upNext
    case system
}

/// Which item the presentation layer must retain until Cinema finalization completes.
///
/// The reducer deliberately does not own `MediaItem`: transition correctness depends on identity
/// and availability, while the visionOS composition layer remains responsible for retaining the
/// concrete current/next item used by the eventual navigation action.
enum CinemaReturnSelection: Equatable, Sendable {
    case none
    case currentItem
    case nextItem
}

/// Typed, backend-neutral exit intent captured before dismissal starts.
struct CinemaExitRequest: Equatable, Sendable {
    let cause: CinemaExitCause
    let origin: CinemaOrigin
    let returnSelection: CinemaReturnSelection

    var destination: CinemaExitDestination {
        CinemaExitRouting.resolve(
            origin: origin,
            hasReturnItem: returnSelection != .none,
            autoPlay: cause == .upNext,
            advancingToNext: cause == .upNext
        )
    }

    static func explicit(origin: CinemaOrigin, hasCurrentItem: Bool) -> Self {
        Self(cause: .explicit,
             origin: origin,
             returnSelection: hasCurrentItem ? .currentItem : .none)
    }

    static func playbackEnded(origin: CinemaOrigin, hasCurrentItem: Bool) -> Self {
        Self(cause: .playbackEnded,
             origin: origin,
             returnSelection: hasCurrentItem ? .currentItem : .none)
    }

    static func upNext(origin: CinemaOrigin, hasNextItem: Bool) -> Self {
        Self(cause: .upNext,
             origin: origin,
             returnSelection: hasNextItem ? .nextItem : .none)
    }

    static func system(origin: CinemaOrigin, hasCurrentItem: Bool) -> Self {
        Self(cause: .system,
             origin: origin,
             returnSelection: hasCurrentItem ? .currentItem : .none)
    }
}

struct CinemaEnteringState: Equatable, Sendable {
    let generation: CinemaTransitionGeneration
    var openConfirmed = false
    var appearanceObserved = false
}

enum CinemaTransitionPhase: Equatable, Sendable {
    case closed
    case entering(CinemaEnteringState)
    case open(CinemaTransitionGeneration)
    case exiting(CinemaTransitionGeneration, CinemaExitRequest)

    var generation: CinemaTransitionGeneration? {
        switch self {
        case .closed:
            nil
        case .entering(let entry):
            entry.generation
        case .open(let generation), .exiting(let generation, _):
            generation
        }
    }
}

struct CinemaTransitionState: Equatable, Sendable {
    fileprivate(set) var phase: CinemaTransitionPhase = .closed
    fileprivate(set) var lastIssuedGeneration: CinemaTransitionGeneration?
    fileprivate(set) var lastFinalizedGeneration: CinemaTransitionGeneration?
}

enum CinemaTransitionEvent: Equatable, Sendable {
    case enterRequested
    case entryCompleted(CinemaTransitionGeneration, CinemaEntryResult)
    case immersiveAppeared(CinemaTransitionGeneration)
    /// The normal player window disappearing is expected during the handoff and never finalizes
    /// Cinema. Keeping it as an explicit event makes that ownership rule testable.
    case playerWindowDisappeared(CinemaTransitionGeneration)
    case exitRequested(CinemaTransitionGeneration, CinemaExitRequest)
    /// Disappearance is the single finalization edge. `systemRequest` is used only when no explicit
    /// exit is already in flight (Crown/system collapse); an in-flight request always wins.
    case immersiveDisappeared(CinemaTransitionGeneration, systemRequest: CinemaExitRequest)
}

enum CinemaTransitionAction: Equatable, Sendable {
    case openImmersiveSpace(CinemaTransitionGeneration)
    case detachPlayerWindow(CinemaTransitionGeneration)
    case entryRejected(CinemaTransitionGeneration, CinemaEntryResult)
    case dismissImmersiveSpace(CinemaTransitionGeneration)
    case finalize(CinemaTransitionGeneration, CinemaExitRequest, CinemaExitDestination)
}

/// Pure visionOS Cinema transition reducer.
///
/// SwiftUI/immersive APIs execute the returned actions, then feed their generation-tagged results
/// back into this reducer. No view callback independently stops playback, routes navigation, or
/// reopens a window: every exit cause converges on `immersiveDisappeared`, which emits at most one
/// finalization action for a generation.
enum CinemaTransitionCoordinatorPolicy {
    static func reduce(state: inout CinemaTransitionState,
                       event: CinemaTransitionEvent) -> [CinemaTransitionAction] {
        switch event {
        case .enterRequested:
            guard case .closed = state.phase else { return [] }
            let previous = state.lastIssuedGeneration?.rawValue ?? 0
            precondition(previous < UInt64.max, "Cinema transition generation exhausted")
            let generation = CinemaTransitionGeneration(rawValue: previous + 1)
            state.lastIssuedGeneration = generation
            state.phase = .entering(CinemaEnteringState(generation: generation))
            return [.openImmersiveSpace(generation)]

        case .entryCompleted(let generation, let result):
            guard case .entering(var entry) = state.phase,
                  entry.generation == generation else { return [] }
            switch result {
            case .opened:
                // Opening is not enough to detach the player window: the immersive scene must
                // also have appeared. Whichever event supplies the second fact emits the one
                // detach action; duplicate completion remains a no-op.
                guard !entry.openConfirmed else { return [] }
                entry.openConfirmed = true
                if entry.appearanceObserved {
                    state.phase = .open(generation)
                    return [.detachPlayerWindow(generation)]
                }
                state.phase = .entering(entry)
                return []
            case .userCancelled, .failed:
                state.phase = .closed
                return [.entryRejected(generation, result)]
            }

        case .immersiveAppeared(let generation):
            guard case .entering(var entry) = state.phase,
                  entry.generation == generation else { return [] }
            guard !entry.appearanceObserved else { return [] }
            entry.appearanceObserved = true
            if entry.openConfirmed {
                state.phase = .open(generation)
                return [.detachPlayerWindow(generation)]
            }
            state.phase = .entering(entry)
            return []

        case .playerWindowDisappeared(let generation):
            // Window disappearance is a handoff side effect, not a Cinema exit. The generation
            // check still rejects a late callback without granting it any transition authority.
            guard state.phase.generation == generation else { return [] }
            return []

        case .exitRequested(let generation, let request):
            guard state.phase.generation == generation else { return [] }
            switch state.phase {
            case .entering(_), .open(_):
                state.phase = .exiting(generation, request)
                return [.dismissImmersiveSpace(generation)]
            case .closed, .exiting(_, _):
                return []
            }

        case .immersiveDisappeared(let generation, let systemRequest):
            guard state.phase.generation == generation else { return [] }
            let request: CinemaExitRequest
            switch state.phase {
            case .entering(_), .open(_):
                request = systemRequest
            case .exiting(_, let inFlightRequest):
                request = inFlightRequest
            case .closed:
                return []
            }
            guard state.lastFinalizedGeneration != generation else { return [] }
            state.lastFinalizedGeneration = generation
            state.phase = .closed
            return [.finalize(generation, request, request.destination)]
        }
    }
}
