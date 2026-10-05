import Foundation
import Testing
import PMSKit
@testable import Labstream

@MainActor
struct EmbyReopenStopBarrierTests {
    @Test func failedStopRetainsExactAuthorityForRetry() async {
        let barrier = EmbyReopenStopBarrier()
        var calls = 0
        var operation: (() async -> Bool)? = { calls += 1; return calls > 1 }
        let first = barrier.begin(stop: &operation)
        #expect(operation == nil)
        #expect(await first.value == false)
        #expect(barrier.hasAuthority)
        var retry: (() async -> Bool)?
        #expect(await barrier.begin(stop: &retry).value)
        #expect(calls == 2)
        #expect(!barrier.hasAuthority)
    }

    @Test func overlappingAndCancelledWaitersJoinSingleStop() async {
        let barrier = EmbyReopenStopBarrier()
        let gate = Gate()
        var calls = 0
        var operation: (() async -> Bool)? = { calls += 1; await gate.wait(); return true }
        let first = barrier.begin(stop: &operation)
        var secondOperation: (() async -> Bool)?
        let second = barrier.begin(stop: &secondOperation)
        let waiter = Task { @MainActor in
            let result = await first.value
            return result && RemoteStreamLifecyclePolicy.acceptsReopenResult(
                capturedGeneration: 1, currentGeneration: 2, isCancelled: Task.isCancelled)
        }
        waiter.cancel()
        await gate.release()
        #expect(await second.value)
        #expect(await waiter.value == false)
        #expect(calls == 1)
        #expect(!barrier.hasAuthority)
    }

    @Test func missingAcknowledgementNeverConfirmsStop() async {
        let barrier = EmbyReopenStopBarrier()
        var absent: (() async -> Bool)?
        #expect(await barrier.begin(stop: &absent).value == false)
        #expect(!barrier.hasAuthority)
    }

    @Test func nonEncodingAuthorityCanAcknowledgeWithoutNetworkAndReuseSessionAfterStop() async {
        let barrier = EmbyReopenStopBarrier()
        var noEncoding: (() async -> Bool)? = { true }
        #expect(await barrier.begin(stop: &noEncoding).value)
        #expect(!barrier.hasAuthority)
        // A newly opened encoder may reuse an ID: its new immutable stop ticket is independent.
        var calls = 0
        var reusedSession: (() async -> Bool)? = { calls += 1; return true }
        #expect(await barrier.begin(stop: &reusedSession).value)
        #expect(calls == 1)
    }

    @Test func controllerReopensOnlyNewestGenerationAfterAcknowledgedStop() async throws {
        let gate = Gate()
        var events: [String] = []
        let identity = ClientIdentity(clientIdentifier: "fixture", product: "Labstream", version: "1", deviceName: "Test")
        let session = MediaBrowserPlaybackSession(
            streamURL: URL(string: "https://fixture.invalid/master.m3u8")!, backend: .emby,
            backendLabel: "Emby", httpHeaders: [:], playSessionID: "same-session",
            sourceMetadata: MediaBrowserPlaybackSourceMetadata(videoCodec: "hevc"),
            playMethod: .transcode, transcodeReasons: [], progressSession: nil,
            onStop: { events.append("legacy-stop") },
            reopener: { request in
                events.append("reopen-\(request.bitrateKbps)")
                throw CancellationError()
            },
            onStopAcknowledged: {
                events.append("stop-start")
                await gate.wait()
                events.append("stop-acknowledged")
                return true
            })
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 600_000),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 8000)
        controller.reload(bitrateKbps: 12000)
        for _ in 0..<1000 where events.isEmpty { await Task.yield() }
        #expect(events == ["stop-start"])
        controller.reload(bitrateKbps: 4000)
        await gate.release()
        for _ in 0..<1000 where events.count < 3 { await Task.yield() }
        #expect(events == ["stop-start", "stop-acknowledged", "reopen-4000"])
        controller.stop()
        await controller.waitForPendingStopRequests()
        #expect(!events.contains("legacy-stop"))
    }

    @Test func supersededNegotiationCleansReplacementBeforeNewestNegotiates() async throws {
        let negotiated = Gate()
        var events: [String] = []
        let identity = ClientIdentity(clientIdentifier: "fixture", product: "Labstream", version: "1", deviceName: "Test")
        let url = URL(string: "https://fixture.invalid/master.m3u8")!
        let session = MediaBrowserPlaybackSession(
            streamURL: url, backend: .emby, backendLabel: "Emby", httpHeaders: [:],
            playSessionID: "fixture", sourceMetadata: MediaBrowserPlaybackSourceMetadata(videoCodec: "hevc"),
            playMethod: .transcode, transcodeReasons: [], progressSession: nil, onStop: {},
            reopener: { request in
                events.append("negotiate-\(request.bitrateKbps)")
                if request.bitrateKbps == 12000 {
                    await negotiated.wait()
                    return RemoteStreamOpenResult(url: url, headers: [:], playSessionId: "fixture",
                        onStopAcknowledged: { events.append("cleanup-stale"); return true })
                }
                throw CancellationError()
            }, onStopAcknowledged: { events.append("stop-old"); return true })
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 600_000),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 8000)
        controller.reload(bitrateKbps: 12000)
        for _ in 0..<1000 where events.count < 2 { await Task.yield() }
        controller.reload(bitrateKbps: 4000)
        await Task.yield()
        #expect(events == ["stop-old", "negotiate-12000"])
        await negotiated.release()
        for _ in 0..<1000 where events.count < 4 { await Task.yield() }
        #expect(events == ["stop-old", "negotiate-12000", "cleanup-stale", "negotiate-4000"])
        controller.stop()
        await controller.waitForPendingStopRequests()
    }

    @Test func unconfirmedStopIsClosedActionableFailure() {
        let failure = PlaybackFailure(code: .priorSessionStopUnconfirmed)
        #expect(PlaybackFailure.classify(failure) == failure)
        #expect(failure.errorDescription?.contains("LS-PB-008") == true)
        #expect(failure.errorDescription?.contains("Retry") == true)
    }

    @Test func finalCleanupRetriesFailedTicketOnlyOnce() async {
        let barrier = EmbyReopenStopBarrier()
        var calls = 0
        var operation: (() async -> Bool)? = { calls += 1; return false }
        #expect(await barrier.begin(stop: &operation).value == false)
        let final = barrier.beginFinalStop()
        #expect(await final?.value == false)
        #expect(barrier.beginFinalStop() == nil)
        #expect(calls == 2)
        #expect(barrier.hasAuthority)
        var retry: (() async -> Bool)?
        #expect(await barrier.begin(stop: &retry).value == false)
        #expect(calls == 3)
    }

    @Test func failedReplacementAuthorityOverridesCapturedSuccessfulOldTicketWithoutRetry() async {
        let barrier = EmbyReopenStopBarrier()
        var old: (() async -> Bool)? = { true }
        let capturedOld = barrier.begin(stop: &old)
        #expect(await capturedOld.value)
        var cleanupCalls = 0
        var replacement: (() async -> Bool)? = { cleanupCalls += 1; return false }
        #expect(await barrier.begin(stop: &replacement).value == false)
        let effective = barrier.currentTicket ?? capturedOld
        #expect(await effective.value == false)
        #expect(cleanupCalls == 1)
        #expect(barrier.hasAuthority)
    }

    @Test func failedSupersededReplacementBlocksNewestNegotiation() async throws {
        let negotiated = Gate()
        var events: [String] = []
        let identity = ClientIdentity(clientIdentifier: "fixture", product: "Labstream", version: "1", deviceName: "Test")
        let url = URL(string: "https://fixture.invalid/master.m3u8")!
        let session = MediaBrowserPlaybackSession(
            streamURL: url, backend: .emby, backendLabel: "Emby", httpHeaders: [:],
            playSessionID: "fixture", sourceMetadata: MediaBrowserPlaybackSourceMetadata(videoCodec: "hevc"),
            playMethod: .transcode, transcodeReasons: [], progressSession: nil, onStop: {},
            reopener: { request in
                events.append("negotiate-\(request.bitrateKbps)")
                if request.bitrateKbps == 12000 {
                    await negotiated.wait()
                    return RemoteStreamOpenResult(url: url, headers: [:], playSessionId: "fixture",
                        onStopAcknowledged: { events.append("cleanup-stale"); return false })
                }
                throw CancellationError()
            }, onStopAcknowledged: { events.append("stop-old"); return true })
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 600_000),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 8000)
        controller.reload(bitrateKbps: 12000)
        for _ in 0..<1000 where events.count < 2 { await Task.yield() }
        controller.reload(bitrateKbps: 4000)
        await Task.yield()
        #expect(events == ["stop-old", "negotiate-12000"])
        await negotiated.release()
        for _ in 0..<1000 where !controller.playbackError.isFailed { await Task.yield() }
        #expect(controller.playbackError.isFailed)
        #expect(!events.contains("negotiate-4000"))
        controller.stop()
        await controller.waitForPendingStopRequests()
        #expect(events.filter { $0 == "cleanup-stale" }.count == 2)
    }

    @Test func terminalStopConsumesAcknowledgedOnlyCallbackOnce() async {
        var acknowledgements = 0
        var legacyStops = 0
        let controller = acknowledgedOnlyController(
            legacyStop: { legacyStops += 1 }, acknowledgedStop: { acknowledgements += 1; return true })
        controller.stop()
        controller.stop()
        await controller.waitForPendingStopRequests()
        #expect(acknowledgements == 1)
        #expect(legacyStops == 0)
    }

    @Test func consentDeclineDoesNotDuplicateAcknowledgedOnlyCleanup() async throws {
        var acknowledgements = 0
        var legacyStops = 0
        let controller = acknowledgedOnlyController(
            legacyStop: { legacyStops += 1 }, acknowledgedStop: { acknowledgements += 1; return true })
        controller.start()
        for _ in 0..<1000 where !controller.videoTranscodeConsent.isPending { await Task.yield() }
        let generation = try #require(controller.videoTranscodeConsent.generation)
        #expect(acknowledgements == 1)
        controller.declineVideoTranscoding(generation: generation)
        controller.stop()
        await controller.waitForPendingStopRequests()
        #expect(acknowledgements == 1)
        #expect(legacyStops == 0)
    }

    private func acknowledgedOnlyController(legacyStop: @escaping () -> Void,
                                             acknowledgedStop: @escaping () async -> Bool) -> PlaybackController {
        let identity = ClientIdentity(clientIdentifier: "fixture", product: "Labstream", version: "1", deviceName: "Test")
        let session = MediaBrowserPlaybackSession(
            streamURL: URL(string: "https://fixture.invalid/master.m3u8")!, backend: .emby,
            backendLabel: "Emby", httpHeaders: [:], playSessionID: "fixture",
            sourceMetadata: .init(videoCodec: "unsupported"), playMethod: .transcode,
            transcodeReasons: ["VideoCodecNotSupported"], progressSession: nil,
            onStop: legacyStop, reopener: { _ in throw CancellationError() },
            onStopAcknowledged: acknowledgedStop)
        return PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", viewOffset: 120_000),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
    }

    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
    }
}
