#if DEBUG
import AVFoundation
import Foundation
import os
import Testing
@testable import Labstream
import PMSKit

@MainActor
struct PlaybackAgentEvidenceTests {
    @Test func detachedSeekClockRemainsPending() {
        for position in [Double.nan, .infinity, -.infinity, 0, 597.9, 602.1] {
            #expect(!DebugPlaybackScenario.seekTargetReached(positionSeconds: position, targetMs: 600_000))
        }
        for position in [598.0, 600.0, 602.0] {
            #expect(DebugPlaybackScenario.seekTargetReached(positionSeconds: position, targetMs: 600_000))
        }
    }

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
        do {
            try await DebugPlaybackProbeSupport.waitUntilPlayable(controller, phase: "fixture", timeoutSeconds: 1)
            Issue.record("A consent gate must not be reported as playable or time out")
        } catch let error as DebugPlaybackScenario.Blocked {
            #expect(error.reason == .consentRequired)
            #expect(controller.debugEvidenceSnapshot().consent == .pending)
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

    @Test func runStartResetRemovesEveryPreviousCaptureLabel() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        for label in ["plex-initial", "plex-postseek", "emby-initial"] {
            let labelDirectory = directory.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: labelDirectory, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: labelDirectory.appendingPathComponent("frame-00.png"))
        }
        try DebugPlaybackFrameCapture.resetDirectory(at: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try DebugPlaybackFrameCapture.resetDirectory(at: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func delayedTrackReplacementDoesNotAcceptThePredecessor() async throws {
        let old = AVPlayerItem(asset: AVMutableComposition())
        let replacement = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: old)
        let task = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            player.replaceCurrentItem(with: nil)
            try await Task.sleep(for: .milliseconds(20))
            player.replaceCurrentItem(with: replacement)
        }
        defer { task.cancel(); player.replaceCurrentItem(with: nil) }
        try await DebugPlaybackScenario.waitForReplacement(of: old, player: player, timeoutSeconds: 2)
        #expect(player.currentItem === replacement)
        try await task.value
    }

    @Test func missingReplacementFailsClosed() async throws {
        let old = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: old)
        defer { player.replaceCurrentItem(with: nil) }
        do {
            try await DebugPlaybackScenario.waitForReplacement(of: old, player: player, timeoutSeconds: 0)
            Issue.record("The predecessor must not satisfy replacement")
        } catch let error as DebugPlaybackScenario.Blocked {
            #expect(error.reason == .deadline)
        }
    }

    @Test func onlyMetadataSubtitleMechanismsRequireReplacement() {
        #expect(DebugPlaybackScenario.subtitleRequiresReplacement(.plexOff))
        #expect(DebugPlaybackScenario.subtitleRequiresReplacement(.plexStream(1)))
        #expect(DebugPlaybackScenario.subtitleRequiresReplacement(.mediaBrowserOff))
        #expect(DebugPlaybackScenario.subtitleRequiresReplacement(.mediaBrowserStream(1)))
        #expect(!DebugPlaybackScenario.subtitleRequiresReplacement(.avFoundationOff))
        #expect(!DebugPlaybackScenario.subtitleRequiresReplacement(.offlineOff))
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
