#if DEBUG
import AVFoundation
import Foundation
import os
import Testing
@testable import Labstream
import PMSKit

@MainActor
struct PlaybackAgentEvidenceTests {
    @Test(arguments: [MediaBackendKind.jellyfin, .emby])
    func fixtureConsentTransitions(backend: MediaBackendKind) async throws {
        var stopped = false
        var reopened = false
        let identity = ClientIdentity(clientIdentifier: "fixture-only", product: "Labstream", version: "1", deviceName: "Fixture")
        let session = MediaBrowserPlaybackSession(
            streamURL: try #require(URL(string: "https://fixture.invalid/master.m3u8")),
            backend: backend, backendLabel: backend.displayName, httpHeaders: [:],
            playSessionID: "private-sentinel", sourceMetadata: .init(videoCodec: "unsupported"),
            playMethod: .transcode, transcodeReasons: ["VideoCodecNotSupported"],
            progressSession: nil, onStop: {}, reopener: { _ in
                reopened = true
                throw URLError(.cancelled)
            }, onStopAndWait: { stopped = true })
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "private-sentinel", title: "private-sentinel", type: "movie"),
            sessionSource: .mediaBrowser(session), identity: identity,
            client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
        defer { controller.stop() }
        controller.start()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !controller.videoTranscodeConsent.isPending, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let generation = try #require(controller.videoTranscodeConsent.generation)
        let pending = controller.debugEvidenceSnapshot()
        #expect(pending.backend.rawValue == backend.rawValue)
        #expect(pending.consent == .pending)
        #expect(pending.phase == .consent)
        #expect(pending.visibleAttachment == .detached)
        #expect(pending.videoDecision == .unknown)
        #expect(pending.serverCleanup == "unknown")
        #expect(stopped && !reopened)
        controller.declineVideoTranscoding(generation: generation)
        #expect(controller.debugEvidenceSnapshot().consent == .notPending)
        controller.stop()
        controller.approveVideoTranscoding(generation: generation)
        #expect(!reopened)
        let terminal = controller.debugEvidenceSnapshot()
        #expect(terminal.cleanupRequested)
        #expect(terminal.phase == .stopped)
        #expect(terminal.generation != pending.generation)
        let data = try JSONEncoder().encode(terminal)
        #expect(!String(decoding: data, as: UTF8.self).contains("private-sentinel"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set(["buildNumber", "phase", "bufferBucketSeconds", "renderedFormat", "schemaVersion",
            "generation", "backend", "qualityKbps", "videoDecision", "videoProvenance", "audioDecision", "consent",
            "visibleAttachment", "positionBucketSeconds", "cleanupRequested", "serverCleanup"]))
    }

    @Test func changedBackendStopsBeforeStartingPlayback() async throws {
        let identity = ClientIdentity(clientIdentifier: "fixture-only", product: "Labstream",
                                      version: "1", deviceName: "Fixture")
        let controller = PlaybackController(
            item: MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie"),
            sessionSource: .offline(OfflinePlaybackSession(fileURL: URL(fileURLWithPath: "/fixture.invalid"))),
            identity: identity, client: PlexClient(identity: identity), maxVideoBitrateKbps: 0)
        let arguments = ["--vp-probe-query", "Fixture", "--vp-probe-allow-live", "--vp-probe-scenario", "original"]
        let options = try #require(DebugPlaybackProbeSupport.launchOptions(from: arguments, defaultBitrateKbps: 0))
        do {
            try await DebugPlaybackScenario.run(controller, options: options, arguments: arguments,
                backendIsCurrent: { false }, log: Logger(subsystem: "fixture", category: "fixture"))
            Issue.record("A stale backend must not run playback")
        } catch let error as DebugPlaybackScenario.Blocked {
            #expect(error.reason == .backendChanged)
        }
        #expect(controller.debugEvidenceSnapshot().cleanupRequested)
        #expect(controller.player.currentItem == nil)
    }

    @Test func admissionIsSeparateForVideoEncoding() {
        #expect(!DebugPlaybackScenario.admitted([], bitrateKbps: 0))
        #expect(DebugPlaybackScenario.admitted(["--vp-probe-allow-live", "--vp-probe-scenario", "original"], bitrateKbps: 0))
        #expect(!DebugPlaybackScenario.admitted(["--vp-probe-allow-live", "--vp-probe-scenario", "consentApprove"], bitrateKbps: 0))
        #expect(!DebugPlaybackScenario.admitted(["--vp-probe-allow-live"], bitrateKbps: 8_000))
        #expect(DebugPlaybackScenario.admitted(["--vp-probe-allow-live", "--vp-probe-allow-video-encode",
                                               "--vp-probe-scenario", "consentApprove"], bitrateKbps: 0))
        #expect(DebugPlaybackScenario.name(["--vp-probe-scenario", "unknown-command"]) == nil)
    }

    @Test func invalidOptionsFailClosed() {
        for extra in [["--vp-probe-post-seek-hold-seconds", "-1"],
                      ["--vp-probe-stall-tolerance-seconds", "999999999999999999999"],
                      ["--vp-probe-seek-ms", "oops"]] {
            #expect(DebugPlaybackProbeSupport.launchOptions(from: ["--vp-probe-query", "Fixture"] + extra,
                                                             defaultBitrateKbps: 0) == nil)
        }
    }
}
#endif
