import Observation
import PMSKit

enum CinemaPresentationState: Equatable, Sendable {
    case closed
    case inTransition
    case open
}

/// App-lifetime executor for the pure Cinema transition policy.
///
/// Views provide visionOS environment actions as effects, but never mutate presentation state or
/// finalize a Cinema session themselves. Every async result returns through the generation-fenced
/// reducer before an effect is allowed to run.
@Observable
@MainActor
final class CinemaTransitionCoordinator {
    private(set) var state = CinemaTransitionState()
    @ObservationIgnored private var pendingDetach: (generation: CinemaTransitionGeneration,
                                                     effect: () -> Void)?

    var activeGeneration: CinemaTransitionGeneration? { state.phase.generation }

    var presentationState: CinemaPresentationState {
        switch state.phase {
        case .closed:
            .closed
        case .open:
            .open
        case .entering(_), .exiting(_, _):
            .inTransition
        }
    }

    func enter(openImmersiveSpace: () async -> CinemaEntryResult,
               detachPlayerWindow: @escaping () -> Void) async {
        let actions = reduce(.enterRequested)
        guard actions.count == 1,
              case .openImmersiveSpace(let generation) = actions[0] else { return }
        pendingDetach = (generation, detachPlayerWindow)

        let result = await openImmersiveSpace()
        executeEntryActions(reduce(.entryCompleted(generation, result)))
    }

    /// Returns whether this scaffold belongs to the current entering/open generation. Callers must
    /// not bind callbacks or start maintenance when a stale scene instance returns `false`.
    @discardableResult
    func immersiveDidAppear(generation: CinemaTransitionGeneration) -> Bool {
        switch state.phase {
        case .entering(let entry) where entry.generation == generation:
            executeEntryActions(reduce(.immersiveAppeared(generation)))
            return ownsActiveScaffold(generation: generation)
        case .open(let current) where current == generation:
            return true
        default:
            return false
        }
    }

    func ownsScaffold(generation: CinemaTransitionGeneration) -> Bool {
        state.phase.generation == generation
    }

    func ownsActiveScaffold(generation: CinemaTransitionGeneration) -> Bool {
        switch state.phase {
        case .entering(let entry):
            entry.generation == generation
        case .open(let current):
            current == generation
        case .closed, .exiting(_, _):
            false
        }
    }

    func playerWindowDidDisappear(generation: CinemaTransitionGeneration) {
        _ = reduce(.playerWindowDisappeared(generation))
    }

    func requestExit(generation: CinemaTransitionGeneration,
                     request: CinemaExitRequest,
                     stageReturn: () -> Void,
                     dismissImmersiveSpace: () async -> Void) async {
        let actions = reduce(.exitRequested(generation, request))
        guard actions.contains(.dismissImmersiveSpace(generation)) else { return }
        stageReturn()
        await dismissImmersiveSpace()
    }

    /// Executes the one permitted Cinema finalization order: leave shared playback, stop the one
    /// controller/AVPlayer, route, reopen the main window, then clear retained session metadata.
    func immersiveDidDisappear(
        generation: CinemaTransitionGeneration,
        systemRequest: CinemaExitRequest,
        leaveSharedPlayback: () -> Void,
        stopPlayback: () -> Void,
        route: (CinemaExitRequest, CinemaExitDestination) -> Void,
        openMainWindow: () -> Void,
        clearSession: () -> Void
    ) {
        let actions = reduce(.immersiveDisappeared(generation, systemRequest: systemRequest))
        guard actions.count == 1,
              case .finalize(_, let request, let destination) = actions[0] else { return }
        if pendingDetach?.generation == generation { pendingDetach = nil }

        leaveSharedPlayback()
        stopPlayback()
        route(request, destination)
        openMainWindow()
        clearSession()
    }

    private func reduce(_ event: CinemaTransitionEvent) -> [CinemaTransitionAction] {
        CinemaTransitionCoordinatorPolicy.reduce(state: &state, event: event)
    }

    private func executeEntryActions(_ actions: [CinemaTransitionAction]) {
        for action in actions {
            switch action {
            case .detachPlayerWindow(let generation):
                guard let pendingDetach,
                      pendingDetach.generation == generation else { continue }
                self.pendingDetach = nil
                pendingDetach.effect()
            case .entryRejected(let generation, _):
                if pendingDetach?.generation == generation { pendingDetach = nil }
            case .openImmersiveSpace(_), .dismissImmersiveSpace(_), .finalize(_, _, _):
                break
            }
        }
    }
}
