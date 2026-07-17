import Testing
@testable import Labstream

@MainActor
struct PlaybackLifecycleCallbackSinkTests {
    @Test func queuedVideoCallbacksCannotMutateAfterFinalStopped() {
        let currentGeneration = GenerationBox(1)
        let sink = PlaybackLifecycleCallbackSink<Int> { $0 == currentGeneration.value }
        var reports: [String] = []
        var markerVisible = false
        var playing = false

        let queuedHeartbeat = {
            sink.perform(.videoHeartbeat, generation: 1) { reports.append("playing") }
        }
        let queuedMarker = {
            sink.perform(.videoMarker, generation: 1) { markerVisible = true }
        }
        let queuedPlaying = {
            sink.perform(.videoPlaying, generation: 1) { playing = true }
        }

        currentGeneration.value = 2 // stop invalidates first, then publishes the terminal event
        reports.append("stopped")
        _ = queuedHeartbeat()
        _ = queuedMarker()
        _ = queuedPlaying()

        #expect(reports == ["stopped"])
        #expect(!markerVisible)
        #expect(!playing)
    }

    @Test func queuedMusicCallbacksCannotResurrectStoppedOrReplacementState() {
        let currentGeneration = GenerationBox<UInt64>(10)
        let sink = PlaybackLifecycleCallbackSink<UInt64> { $0 == currentGeneration.value }
        var elapsed = 0.0
        var playing = false
        var artwork = "new-art"
        var audioResumed = false
        var reports = ["stopped"]

        let queuedTick = { sink.perform(.musicTick, generation: 10) { elapsed = 42 } }
        let queuedStatus = {
            sink.perform(.musicStatus, generation: 10) {
                playing = true
                reports.append("playing")
            }
        }
        let queuedArtwork = {
            sink.perform(.musicArtwork, generation: 10) { artwork = "old-art" }
        }
        let queuedAudio = {
            sink.perform(.musicAudioSession, generation: 10) { audioResumed = true }
        }

        currentGeneration.value = 11
        _ = queuedTick()
        _ = queuedStatus()
        _ = queuedArtwork()
        _ = queuedAudio()

        #expect(elapsed == 0)
        #expect(!playing)
        #expect(artwork == "new-art")
        #expect(!audioResumed)
        #expect(reports == ["stopped"])
    }

    @Test func nestedVideoBoundariesEachInvalidateEarlierAuthority() {
        let current = GenerationBox(0)
        let sink = PlaybackLifecycleCallbackSink<Int> { $0 == current.value }
        let configured = current.value
        current.value += 1 // stream request/restart boundary
        #expect(!sink.accepts(.videoHeartbeat, generation: configured))
        let request = current.value
        current.value += 1 // item attachment boundary
        #expect(!sink.accepts(.videoHeartbeat, generation: request))
        let item = current.value
        #expect(sink.accepts(.videoHeartbeat, generation: item))
    }
}

@MainActor
private final class GenerationBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
