import MediaPlayer
import Testing
@testable import Labstream

@MainActor
struct SystemMediaSessionCoordinatorTests {
    @Test func musicVideoMusicRestoresPreviousOwner() throws {
        let backend = FakeSystemMediaSessionBackend()
        let coordinator = SystemMediaSessionCoordinator(backend: backend)
        let events = EventRecorder()
        let music = try #require(coordinator.acquire(owner: .music,
            commands: configuration(label: "music", events: events)))
        music.publish(nowPlayingInfo: [MPMediaItemPropertyTitle: "Song"], playbackState: .playing)

        let video = try #require(coordinator.acquire(owner: .video,
            commands: configuration(label: "video", events: events)))
        video.publish(nowPlayingInfo: [MPMediaItemPropertyTitle: "Film"], playbackState: .playing)
        #expect(!music.isCurrent)
        #expect(video.isCurrent)
        backend.invoke(.play)
        #expect(events.values == ["video"])

        video.release()
        #expect(music.isCurrent)
        #expect(backend.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "music")
        backend.invoke(.play)
        #expect(events.values == ["video", "music"])
    }

    @Test func musicStopWhileVideoOwnsControlsDoesNotDisturbVideo() throws {
        let backend = FakeSystemMediaSessionBackend()
        let coordinator = SystemMediaSessionCoordinator(backend: backend)
        let events = EventRecorder()
        let music = try #require(coordinator.acquire(owner: .music,
            commands: configuration(label: "music", events: events)))
        let video = try #require(coordinator.acquire(owner: .video,
            commands: configuration(label: "video", events: events)))

        music.release()
        #expect(video.isCurrent)
        backend.invoke(.play)
        #expect(events.values == ["video"])
        video.release()
        #expect(backend.targets.isEmpty)
    }

    @Test func rapidOwnershipChangesLeaveOnlyNewestTargets() throws {
        let backend = FakeSystemMediaSessionBackend()
        let coordinator = SystemMediaSessionCoordinator(backend: backend)
        let events = EventRecorder()
        let first = try #require(coordinator.acquire(owner: .music,
            commands: configuration(label: "first", events: events)))
        let staleHandler = try #require(backend.targets[.play]?.handler)
        let second = try #require(coordinator.acquire(owner: .video,
            commands: configuration(label: "second", events: events)))
        let third = try #require(coordinator.acquire(owner: .music,
            commands: configuration(label: "third", events: events)))

        #expect(!first.isCurrent && !second.isCurrent && third.isCurrent)
        #expect(backend.targets.count == 1)
        backend.invoke(.play)
        #expect(events.values == ["third"])
        _ = staleHandler(.init())
        #expect(events.values == ["third"])
    }

    @Test func staleArtworkAndStateUpdatesAreRejected() throws {
        let backend = FakeSystemMediaSessionBackend()
        let coordinator = SystemMediaSessionCoordinator(backend: backend)
        let events = EventRecorder()
        let music = try #require(coordinator.acquire(owner: .music,
            commands: configuration(label: "music", events: events)))
        let video = try #require(coordinator.acquire(owner: .video,
            commands: configuration(label: "video", events: events)))
        video.publish(nowPlayingInfo: [MPMediaItemPropertyTitle: "Film"], playbackState: .playing)

        music.publish(nowPlayingInfo: [MPMediaItemPropertyTitle: "Stale song",
                                       MPMediaItemPropertyArtwork: "stale-art"],
                      playbackState: .paused)
        music.clearNowPlaying()
        #expect(backend.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Film")
        #expect(backend.playbackState == .playing)
    }

    @Test func doubleTeardownIsIdempotent() throws {
        let backend = FakeSystemMediaSessionBackend()
        let coordinator = SystemMediaSessionCoordinator(backend: backend)
        let events = EventRecorder()
        let lease = try #require(coordinator.acquire(owner: .music,
            commands: configuration(label: "music", events: events)))

        lease.release()
        lease.release()
        #expect(backend.targets.isEmpty)
        #expect(backend.removeCount == 1)
        #expect(backend.skipForwardIntervals == [99])
        #expect(backend.skipBackwardIntervals == [98])
        #expect(backend.enabled.values.allSatisfy { !$0 })
    }

    @Test func failedActivationRestoresPreviousOwnerWithoutPartialTargets() throws {
        let backend = FakeSystemMediaSessionBackend()
        let coordinator = SystemMediaSessionCoordinator(backend: backend)
        let events = EventRecorder()
        let music = try #require(coordinator.acquire(owner: .music,
            commands: configuration(label: "music", events: events)))
        backend.failNextAdd = true

        let failedVideo = coordinator.acquire(owner: .video,
            commands: configuration(label: "video", events: events))
        #expect(failedVideo == nil)
        #expect(music.isCurrent)
        #expect(backend.targets.count == 1)
        backend.invoke(.play)
        #expect(events.values == ["music"])
    }

    private func configuration(label: String, events: EventRecorder)
        -> SystemMediaSessionCoordinator.CommandConfiguration {
        .init(handlers: [.play: { _ in
            events.values.append(label)
            return .success
        }], didBecomeCurrent: { lease in
            lease.publish(nowPlayingInfo: [MPMediaItemPropertyTitle: label], playbackState: .playing)
        })
    }
}

@MainActor
private final class EventRecorder {
    var values: [String] = []
}

@MainActor
private final class FakeSystemMediaSessionBackend: SystemMediaSessionBackend {
    private struct AddFailure: Error {}
    private final class Token {}

    var nowPlayingInfo: [String: Any]?
    var playbackState: MPNowPlayingPlaybackState = .stopped
    var enabled = Dictionary(uniqueKeysWithValues:
        SystemMediaSessionCoordinator.Command.allCases.map { ($0, false) })
    var skipForwardIntervals: [NSNumber] = [99]
    var skipBackwardIntervals: [NSNumber] = [98]
    var targets: [SystemMediaSessionCoordinator.Command:
                  (token: Any, handler: SystemMediaSessionCoordinator.CommandConfiguration.Handler)] = [:]
    var failNextAdd = false
    var removeCount = 0

    func captureCommandState() -> SystemMediaCommandState {
        .init(enabled: enabled, skipForwardIntervals: skipForwardIntervals,
              skipBackwardIntervals: skipBackwardIntervals)
    }

    func apply(configuration: SystemMediaSessionCoordinator.CommandConfiguration) {
        for command in SystemMediaSessionCoordinator.Command.allCases {
            enabled[command] = configuration.handlers[command] != nil
        }
        skipForwardIntervals = configuration.skipForwardIntervals
        skipBackwardIntervals = configuration.skipBackwardIntervals
    }

    func restoreCommandState(_ state: SystemMediaCommandState) {
        enabled = state.enabled
        skipForwardIntervals = state.skipForwardIntervals
        skipBackwardIntervals = state.skipBackwardIntervals
    }

    func addTarget(for command: SystemMediaSessionCoordinator.Command,
                   handler: @escaping SystemMediaSessionCoordinator.CommandConfiguration.Handler) throws -> Any {
        if failNextAdd {
            failNextAdd = false
            throw AddFailure()
        }
        let token = Token()
        targets[command] = (token, handler)
        return token
    }

    func removeTarget(_ target: Any, for command: SystemMediaSessionCoordinator.Command) {
        guard targets[command]?.token as AnyObject === target as AnyObject else { return }
        targets[command] = nil
        removeCount += 1
    }

    func invoke(_ command: SystemMediaSessionCoordinator.Command,
                event: SystemMediaSessionCoordinator.CommandEvent = .init()) {
        _ = targets[command]?.handler(event)
    }
}
