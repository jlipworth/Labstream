#if os(visionOS)
import PMSKit
import Testing
@testable import Labstream

@Suite("Cinema transition policy")
struct CinemaTransitionPolicyTests {
    @Test("Entry succeeds only after open confirmation and immersive appearance")
    func entrySuccess() {
        var state = CinemaTransitionState()
        let generation = requestEntry(state: &state)

        #expect(reduce(&state, .immersiveAppeared(generation)).isEmpty)
        #expect(state.phase == .entering(CinemaEnteringState(
            generation: generation, openConfirmed: false, appearanceObserved: true)))
        #expect(reduce(&state, .entryCompleted(generation, .opened)) ==
                [.detachPlayerWindow(generation)])
        #expect(state.phase == .open(generation))
    }

    @Test("Cancelled and failed entries return to closed without detaching the player")
    func entryFailure() {
        for result in [CinemaEntryResult.userCancelled, .failed] {
            var state = CinemaTransitionState()
            let generation = requestEntry(state: &state)
            #expect(reduce(&state, .entryCompleted(generation, result)) ==
                    [.entryRejected(generation, result)])
            #expect(state.phase == .closed)
        }
    }

    @Test("Duplicate opened completion detaches the player window exactly once")
    func duplicateOpenedCompletion() {
        var state = CinemaTransitionState()
        let generation = requestEntry(state: &state)

        #expect(reduce(&state, .entryCompleted(generation, .opened)).isEmpty)
        #expect(reduce(&state, .entryCompleted(generation, .opened)).isEmpty)
        #expect(state.phase == .entering(CinemaEnteringState(
            generation: generation, openConfirmed: true, appearanceObserved: false)))

        #expect(reduce(&state, .immersiveAppeared(generation)) ==
                [.detachPlayerWindow(generation)])
        #expect(reduce(&state, .immersiveAppeared(generation)).isEmpty)
        #expect(state.phase == .open(generation))
    }

    @Test("Open confirmation without immersive appearance retains the player window")
    func missingAppearanceRetainsWindow() {
        var state = CinemaTransitionState()
        let generation = requestEntry(state: &state)

        #expect(reduce(&state, .entryCompleted(generation, .opened)).isEmpty)
        #expect(reduce(&state, .playerWindowDisappeared(generation)).isEmpty)
        #expect(state.phase == .entering(CinemaEnteringState(
            generation: generation, openConfirmed: true, appearanceObserved: false)))
    }

    @Test("Player window disappearance during entry or open never finalizes Cinema")
    func playerWindowDisappearanceIsNotExit() {
        var state = CinemaTransitionState()
        let generation = requestEntry(state: &state)
        #expect(reduce(&state, .playerWindowDisappeared(generation)).isEmpty)
        #expect(state.phase.generation == generation)

        open(generation, state: &state)
        #expect(reduce(&state, .playerWindowDisappeared(generation)).isEmpty)
        #expect(state.phase == .open(generation))
        #expect(state.lastFinalizedGeneration == nil)
    }

    @Test("Explicit, EOF, Up Next, and system exits share one finalization edge")
    func exitCausesConverge() {
        let explicit = CinemaExitRequest.explicit(origin: .onlineTab(.libraries),
                                                  hasCurrentItem: true)
        let ended = CinemaExitRequest.playbackEnded(origin: .onlineTab(.libraries),
                                                    hasCurrentItem: true)
        let upNext = CinemaExitRequest.upNext(origin: .onlineTab(.libraries), hasNextItem: true)
        let system = CinemaExitRequest.system(origin: .onlineTab(.libraries),
                                              hasCurrentItem: true)

        for request in [explicit, ended, upNext] {
            var state = CinemaTransitionState()
            let generation = requestEntry(state: &state)
            open(generation, state: &state)
            #expect(reduce(&state, .exitRequested(generation, request)) ==
                    [.dismissImmersiveSpace(generation)])
            #expect(reduce(&state, .immersiveDisappeared(generation,
                                                        systemRequest: system)) ==
                    [.finalize(generation, request, request.destination)])
            #expect(state.phase == .closed)
        }

        var state = CinemaTransitionState()
        let generation = requestEntry(state: &state)
        open(generation, state: &state)
        #expect(reduce(&state, .immersiveDisappeared(generation, systemRequest: system)) ==
                [.finalize(generation, system, system.destination)])
    }

    @Test("A generation finalizes exactly once even when disappearance repeats")
    func exactOnceFinalization() {
        var state = CinemaTransitionState()
        let generation = requestEntry(state: &state)
        open(generation, state: &state)
        let request = CinemaExitRequest.explicit(origin: .systemEntry, hasCurrentItem: true)
        _ = reduce(&state, .exitRequested(generation, request))

        #expect(reduce(&state, .immersiveDisappeared(generation,
                                                    systemRequest: request)).count == 1)
        #expect(reduce(&state, .immersiveDisappeared(generation,
                                                    systemRequest: request)).isEmpty)
        #expect(state.lastFinalizedGeneration == generation)
    }

    @Test("Callbacks from a prior generation cannot mutate a newer entry")
    func generationFencing() {
        var state = CinemaTransitionState()
        let first = requestEntry(state: &state)
        _ = reduce(&state, .entryCompleted(first, .failed))
        let second = requestEntry(state: &state)

        #expect(second > first)
        #expect(reduce(&state, .entryCompleted(first, .opened)).isEmpty)
        #expect(reduce(&state, .immersiveAppeared(first)).isEmpty)
        #expect(reduce(&state, .immersiveDisappeared(
            first, systemRequest: .system(origin: .systemEntry, hasCurrentItem: true))).isEmpty)
        #expect(state.phase.generation == second)
    }

    @Test("Missing online items route nowhere while offline always returns locally")
    func missingAndOfflineRouting() {
        let missing = CinemaExitRequest.system(origin: .onlineTab(.search),
                                               hasCurrentItem: false)
        #expect(missing.destination == .none)

        let offlineMissing = CinemaExitRequest.system(origin: .offline(ratingKey: "emby:item-9"),
                                                      hasCurrentItem: false)
        #expect(offlineMissing.destination == .offlineDownload(ratingKey: "emby:item-9"))

        let offlineUpNext = CinemaExitRequest.upNext(origin: .offline(ratingKey: "plex:item-7"),
                                                    hasNextItem: true)
        #expect(offlineUpNext.destination == .offlineDownload(ratingKey: "plex:item-7"))
    }

    @Test("Runtime coordinator executes one ordered finalization")
    @MainActor
    func runtimeCoordinatorFinalizationOrder() async throws {
        let coordinator = CinemaTransitionCoordinator()
        var effects: [String] = []

        await coordinator.enter(
            openImmersiveSpace: { .opened },
            detachPlayerWindow: { effects.append("detach") })
        let generation = try #require(coordinator.activeGeneration)
        #expect(effects.isEmpty)
        #expect(coordinator.immersiveDidAppear(generation: generation))
        #expect(effects == ["detach"])

        let request = CinemaExitRequest.upNext(origin: .onlineTab(.libraries),
                                               hasNextItem: true)
        await coordinator.requestExit(
            generation: generation,
            request: request,
            stageReturn: { effects.append("stage") },
            dismissImmersiveSpace: { effects.append("dismiss") })
        coordinator.immersiveDidDisappear(
            generation: generation,
            systemRequest: .system(origin: .systemEntry, hasCurrentItem: true),
            leaveSharedPlayback: { effects.append("leave") },
            stopPlayback: { effects.append("stop") },
            route: { routedRequest, destination in
                #expect(routedRequest == request)
                #expect(destination == .onlineTabItem(tab: .libraries, autoPlay: true))
                effects.append("route")
            },
            openMainWindow: { effects.append("open-window") },
            clearSession: { effects.append("clear") })

        #expect(effects == ["detach", "stage", "dismiss", "leave", "stop", "route",
                            "open-window", "clear"])

        coordinator.immersiveDidDisappear(
            generation: generation,
            systemRequest: request,
            leaveSharedPlayback: { effects.append("duplicate-leave") },
            stopPlayback: { effects.append("duplicate-stop") },
            route: { _, _ in effects.append("duplicate-route") },
            openMainWindow: { effects.append("duplicate-open") },
            clearSession: { effects.append("duplicate-clear") })
        #expect(effects.last == "clear")
    }

    @Test("Runtime coordinator rejects every stale scaffold effect")
    @MainActor
    func runtimeCoordinatorRejectsStaleScaffold() async throws {
        let coordinator = CinemaTransitionCoordinator()
        var effects: [String] = []

        await coordinator.enter(
            openImmersiveSpace: { .failed },
            detachPlayerWindow: { effects.append("stale-detach") })
        let first = try #require(coordinator.state.lastIssuedGeneration)

        await coordinator.enter(
            openImmersiveSpace: { .opened },
            detachPlayerWindow: { effects.append("current-detach") })
        let second = try #require(coordinator.activeGeneration)
        #expect(second > first)

        #expect(!coordinator.immersiveDidAppear(generation: first))
        #expect(!coordinator.ownsScaffold(generation: first))
        #expect(!coordinator.ownsActiveScaffold(generation: first))
        #expect(effects.isEmpty)

        #expect(coordinator.immersiveDidAppear(generation: second))
        #expect(effects == ["current-detach"])
    }

    private func requestEntry(state: inout CinemaTransitionState) -> CinemaTransitionGeneration {
        let actions = reduce(&state, .enterRequested)
        guard actions.count == 1,
              case .openImmersiveSpace(let generation) = actions[0] else {
            Issue.record("Entry did not request the immersive space")
            return CinemaTransitionGeneration(rawValue: 0)
        }
        return generation
    }

    private func open(_ generation: CinemaTransitionGeneration,
                      state: inout CinemaTransitionState) {
        #expect(reduce(&state, .entryCompleted(generation, .opened)).isEmpty)
        #expect(reduce(&state, .immersiveAppeared(generation)) ==
                [.detachPlayerWindow(generation)])
        #expect(state.phase == .open(generation))
    }

    private func reduce(_ state: inout CinemaTransitionState,
                        _ event: CinemaTransitionEvent) -> [CinemaTransitionAction] {
        CinemaTransitionCoordinatorPolicy.reduce(state: &state, event: event)
    }
}
#endif
