import Foundation
import PMSKit
import Testing
@testable import Labstream

@MainActor
struct PlaybackPresentationCallbackTests {
    @Test func staleOwnerCannotClearReplacementCallbacks() {
        let controller = makeCallbackController()
        let old = UUID()
        let replacement = UUID()
        var events: [String] = []
        controller.bindPresentationCallbacks(owner: old, advance: { _ in events.append("old-next") },
                                             ended: { events.append("old-end") })
        controller.bindPresentationCallbacks(owner: replacement,
                                             advance: { _ in events.append("next") },
                                             ended: { events.append("end") })
        controller.clearPresentationCallbacks(owner: old)
        controller.onAdvanceToNext?(controller.item)
        controller.onPlaybackEnded?()
        #expect(events == ["next", "end"])
        #expect(controller.ownsPresentationCallbacks(replacement))
        controller.clearPresentationCallbacks(owner: replacement)
        #expect(controller.onAdvanceToNext == nil)
        #expect(controller.onPlaybackEnded == nil)
    }

    @Test func directPresenterAssignmentRevokesOldCleanupAuthority() {
        let controller = makeCallbackController()
        let owner = UUID()
        controller.bindPresentationCallbacks(owner: owner, advance: { _ in }, ended: {})
        var ended = false
        controller.onPlaybackEnded = { ended = true }
        controller.clearPresentationCallbacks(owner: owner)
        controller.onPlaybackEnded?()
        #expect(ended)
        #expect(!controller.ownsPresentationCallbacks(owner))
    }

    @Test func stopReleasesAllPresentationClosuresAndTheirCaptures() {
        let controller = makeCallbackController()
        var capture: CallbackCapture? = CallbackCapture()
        weak var releasedCapture = capture
        let owner = UUID()
        controller.bindPresentationCallbacks(owner: owner,
                                             advance: { [capture] _ in _ = capture },
                                             ended: { [capture] in _ = capture })
        controller.onPlaybackActive = { [capture] in _ = capture }
        capture = nil
        #expect(releasedCapture != nil)
        controller.stop()
        #expect(releasedCapture == nil)
        #expect(controller.onAdvanceToNext == nil)
        #expect(controller.onPlaybackEnded == nil)
        #expect(controller.onPlaybackActive == nil)
        #expect(!controller.ownsPresentationCallbacks(owner))
        controller.stop()
    }
}

@MainActor
private final class CallbackCapture {}

@MainActor
private func makeCallbackController() -> PlaybackController {
    let identity = ClientIdentity(clientIdentifier: "callback-fixture", product: "Labstream",
                                  version: "1", deviceName: "Fixture")
    return PlaybackController(
        item: MediaItem(ratingKey: "callback-fixture", title: "Fixture", type: "movie"),
        sessionSource: .offline(OfflinePlaybackSession(fileURL: URL(fileURLWithPath: "/fixture.invalid"))),
        identity: identity, client: PlexClient(identity: identity))
}

#if os(visionOS)
@MainActor
struct CinemaCallbackLifetimeTests {
    @Test func bindingDoesNotRetainSessionOrController() async {
        var session: CustomCinemaSessionStore? = CustomCinemaSessionStore()
        var controller: PlaybackController? = makeCallbackController()
        weak var releasedSession = session
        weak var releasedController = controller
        let binding = CustomCinemaCallbackBinding()
        await session!.transitionCoordinator.enter(openImmersiveSpace: { .opened },
                                                   detachPlayerWindow: {})
        let generation = session!.transitionCoordinator.activeGeneration!
        session!.activate(title: "Fixture", item: controller!.item, controller: controller!)
        binding.bind(session: session!, generation: generation, dismissImmersiveSpace: {})
        #expect(controller!.onPlaybackEnded != nil)
        // No stop/clear: exercise the actual stored Cinema closures, including the indirect
        // session -> controller ownership path which a weak controller capture alone misses.
        controller = nil
        session = nil
        #expect(releasedSession == nil)
        #expect(releasedController == nil)
    }

    @Test func repeatedBindingKeepsOriginalCallbacks() async {
        let session = CustomCinemaSessionStore()
        let controller = makeCallbackController()
        await session.transitionCoordinator.enter(openImmersiveSpace: { .opened },
                                                  detachPlayerWindow: {})
        let generation = session.transitionCoordinator.activeGeneration!
        session.activate(title: "Fixture", item: controller.item, controller: controller)
        let binding = CustomCinemaCallbackBinding()
        var original: CallbackCapture? = CallbackCapture()
        var repeated: CallbackCapture? = CallbackCapture()
        weak var originalCapture = original
        weak var repeatedCapture = repeated
        binding.bind(session: session, generation: generation,
                     dismissImmersiveSpace: { [original] in _ = original })
        binding.bind(session: session, generation: generation,
                     dismissImmersiveSpace: { [repeated] in _ = repeated })
        original = nil
        repeated = nil
        #expect(originalCapture != nil)
        #expect(repeatedCapture == nil)
        binding.clear()
        #expect(originalCapture == nil)
    }

    @Test func oldScaffoldCleanupCannotClearNewScaffoldBinding() async {
        let session = CustomCinemaSessionStore()
        let controller = makeCallbackController()
        await session.transitionCoordinator.enter(openImmersiveSpace: { .opened },
                                                  detachPlayerWindow: {})
        let generation = session.transitionCoordinator.activeGeneration!
        session.activate(title: "Fixture", item: controller.item, controller: controller)
        let old = CustomCinemaCallbackBinding()
        let replacement = CustomCinemaCallbackBinding()
        old.bind(session: session, generation: generation, dismissImmersiveSpace: {})
        replacement.bind(session: session, generation: generation, dismissImmersiveSpace: {})
        old.clear()
        #expect(controller.onAdvanceToNext != nil)
        #expect(controller.onPlaybackEnded != nil)
        replacement.clear()
        #expect(controller.onAdvanceToNext == nil)
        #expect(controller.onPlaybackEnded == nil)
    }
}
#endif
