import PMSKit
import Testing
@testable import Labstream

@MainActor
struct MusicPlaybackLifecycleTests {
    @Test func pendingCatalogQueueRejectsSessionChangeNewIntentAndStop() {
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "queue-intent"))
        let player = MusicPlayerController(appModel: model, artworkPipeline: ArtworkPipeline())
        let old = player.beginQueueIntent()
        #expect(player.acceptsQueueIntent(old))
        let newer = player.beginQueueIntent()
        #expect(!player.acceptsQueueIntent(old))
        #expect(player.acceptsQueueIntent(newer))
        model.activeBackend = model.activeBackend == .plex ? .jellyfin : .plex
        #expect(!player.acceptsQueueIntent(newer))
        let track = MediaItem(ratingKey: "old-track", title: "Fixture", type: "track")
        player.playFetchedTracks([track], shuffled: true, intent: newer)
        #expect(player.queue.isEmpty)
        let superseded = player.beginQueueIntent()
        let current = MediaItem(ratingKey: "new-track", title: "Current", type: "track")
        player.play(tracks: [current], startingAt: 0)
        player.playFetchedTracks([track], shuffled: false, intent: superseded)
        #expect(player.queue.map(\.ratingKey) == ["new-track"])
        let stopped = player.beginQueueIntent()
        player.stop()
        player.playFetchedTracks([track], shuffled: false, intent: stopped)
        #expect(player.queue.isEmpty)
    }

    @Test func suspendedArtistResultCannotReplaceNewerAlbumQueue() async {
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "held-queue"))
        let player = MusicPlayerController(appModel: model, artworkPipeline: ArtworkPipeline())
        var held: CheckedContinuation<[MediaItem], Never>?
        let request = Task { @MainActor in
            let intent = player.beginQueueIntent()
            let tracks = await withCheckedContinuation { held = $0 }
            player.playFetchedTracks(tracks, shuffled: true, intent: intent)
        }
        while held == nil { await Task.yield() }
        player.play(tracks: [MediaItem(ratingKey: "new", title: "Current", type: "track")], startingAt: 0)
        held?.resume(returning: [MediaItem(ratingKey: "old", title: "Old", type: "track")])
        await request.value
        #expect(player.queue.map(\.ratingKey) == ["new"])
        player.stop()
    }

    @Test func artworkAuthoritySurvivesObserverGenerationChangeButNotReplacement() {
        let lifecycle = MusicPlaybackLifecycle()
        let artwork = PlaybackArtworkRequestAuthority()
        let request = artwork.begin()

        _ = lifecycle.advance() // pauseForVideo invalidates observer callbacks only
        #expect(artwork.accepts(request))

        _ = artwork.begin() // selecting/fetching another track invalidates old art
        #expect(!artwork.accepts(request))
    }

    @Test func itemReplacementRejectsQueuedOldItemCallbacks() {
        let lifecycle = MusicPlaybackLifecycle()
        let oldItem = lifecycle.advance()
        var mutations: [String] = []
        let queuedOldStatus = { lifecycle.perform(ifCurrent: oldItem) { mutations.append("status") } }
        let queuedOldEnd = { lifecycle.perform(ifCurrent: oldItem) { mutations.append("end") } }

        let newItem = lifecycle.advance()
        queuedOldStatus()
        queuedOldEnd()
        lifecycle.perform(ifCurrent: newItem) { mutations.append("new") }

        #expect(mutations == ["new"])
    }

    @Test func stopRejectsPlayerArtworkAndAudioCallbacks() {
        let lifecycle = MusicPlaybackLifecycle()
        let playing = lifecycle.advance()
        var mutations: [String] = []
        let queuedCallbacks = ["time", "rate", "heartbeat", "artwork", "interruption", "route"]
            .map { label in { lifecycle.perform(ifCurrent: playing) { mutations.append(label) } } }

        lifecycle.advance() // stop
        queuedCallbacks.forEach { $0() }

        #expect(mutations.isEmpty)
    }

    @Test func configureInvalidatesEarlierConfiguredQueue() {
        let lifecycle = MusicPlaybackLifecycle()
        let queueA = lifecycle.advance()
        let queueB = lifecycle.advance()
        var visibleQueue = "B"

        lifecycle.perform(ifCurrent: queueA) { visibleQueue = "A" }
        lifecycle.perform(ifCurrent: queueB) { visibleQueue = "B-current" }

        #expect(visibleQueue == "B-current")
    }
}
