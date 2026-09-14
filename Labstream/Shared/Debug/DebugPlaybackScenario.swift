#if DEBUG
import AVFoundation
import Foundation
import os
import PMSKit

/// Named, launch-admitted operations only. There is no external interactive command
/// channel, reusable capability, implicit encoding approval, or authentication bypass.
@MainActor
enum DebugPlaybackScenario {
    enum Name: String, Codable { case original, seek, capped, maximum, consentDecline, consentApprove, audio, subtitles }
    enum Status: String, Codable { case passed, failed, blocked }
    enum Reason: String, Codable {
        case completed, missingAdmission, invalidOptions, missingAuth, unsupportedTrack
        case evidenceUnavailable, consentRequired, consentNotPending, decisionUnknown, cancelled, playbackFailed, deadline, backendChanged, staleGeneration
    }
    struct Report: Encodable {
        let schemaVersion = 1
        let evidenceKind = "liveController"
        let scenario: Name
        let status: Status
        let reason: Reason
        let snapshots: [DebugPlaybackEvidence.Snapshot]
    }
    struct Blocked: Error { let reason: Reason }

    static func name(_ arguments: [String]) -> Name? {
        Name(rawValue: DebugPlaybackProbeSupport.value(after: "--vp-probe-scenario", in: arguments) ?? "seek")
    }

    static func admitted(_ arguments: [String], bitrateKbps: Int) -> Bool {
        guard let scenario = name(arguments), arguments.contains("--vp-probe-allow-live") else {
            blocked(arguments, reason: .missingAdmission); return false
        }
        if bitrateKbps > 0 || [.capped, .maximum, .consentApprove].contains(scenario) {
            guard arguments.contains("--vp-probe-allow-video-encode") else {
                blocked(arguments, reason: .missingAdmission); return false
            }
        }
        return true
    }

    static func blocked(_ arguments: [String], reason: Reason) {
        DebugPlaybackEvidence.exportReportIfRequested(Report(scenario: name(arguments) ?? .seek,
            status: .blocked, reason: reason, snapshots: []))
    }

    /// A detached AVPlayerItem reports a non-finite clock during remote reopen.
    /// That is still pending, not a successful comparison or an expired deadline.
    static func seekTargetReached(positionSeconds: Double, targetMs: Int) -> Bool {
        positionSeconds.isFinite && abs(positionSeconds - Double(targetMs) / 1000) <= 2
    }

    static func subtitleRequiresReplacement(_ mechanism: PlaybackSubtitleTrack.Mechanism) -> Bool {
        switch mechanism {
        case .plexOff, .plexStream, .mediaBrowserOff, .mediaBrowserStream: true
        case .avFoundationOff, .avFoundation, .offlineOff, .offlineSidecar: false
        }
    }

    /// A selection call can return before its scheduled restart replaces the old item.
    /// Readiness on that predecessor is not readiness for the requested transition.
    static func waitForReplacement(of priorItem: AVPlayerItem?, player: AVPlayer,
                                   timeoutSeconds: Int,
                                   sessionIsCurrent: () -> Bool = { true },
                                   playbackFailed: () -> Bool = { false },
                                   consentPending: () -> Bool = { false }) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard sessionIsCurrent() else { throw Blocked(reason: .backendChanged) }
            if playbackFailed() { throw Blocked(reason: .playbackFailed) }
            if consentPending() { throw Blocked(reason: .consentRequired) }
            if let current = player.currentItem, current !== priorItem { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw Blocked(reason: .deadline)
    }

    static func run(_ controller: PlaybackController, options: DebugPlaybackProbeSupport.LaunchOptions,
                    arguments: [String], backendIsCurrent: () -> Bool, log: Logger) async throws {
        guard let scenario = name(arguments), admitted(arguments, bitrateKbps: options.bitrateKbps) else {
            throw Blocked(reason: .missingAdmission)
        }
        #if os(macOS)
        let surface = DebugMacPlaybackSurface(controller: controller)
        defer { surface.close() }
        #endif
        var snapshots: [DebugPlaybackEvidence.Snapshot] = []
        var status: Status = .blocked
        var reason: Reason = .deadline
        defer {
            controller.stop()
            snapshots.append(controller.debugEvidenceSnapshot())
            DebugPlaybackEvidence.exportReportIfRequested(Report(scenario: scenario, status: status,
                reason: reason, snapshots: snapshots))
        }
        do {
            try Task.checkCancellation()
            guard backendIsCurrent() else { throw Blocked(reason: .backendChanged) }
            controller.start()
            if [.consentDecline, .consentApprove].contains(scenario) {
                let deadline = ContinuousClock.now.advanced(by: .seconds(options.playableTimeoutSeconds))
                while !controller.videoTranscodeConsent.isPending, ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard backendIsCurrent() else { throw Blocked(reason: .backendChanged) }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard let generation = controller.videoTranscodeConsent.generation else {
                    throw Blocked(reason: .consentNotPending)
                }
                snapshots.append(controller.debugEvidenceSnapshot())
                if scenario == .consentDecline {
                    controller.declineVideoTranscoding(generation: generation)
                    guard !controller.videoTranscodeConsent.isPending else { throw Blocked(reason: .consentNotPending) }
                    status = .passed; reason = .completed
                    return
                }
                // Admission checked independently above. The actual controller validates
                // this exact prompt generation and never persists approval globally.
                controller.approveVideoTranscoding(generation: generation)
            }
            try await DebugPlaybackProbeSupport.waitUntilPlayable(controller, phase: "initial", timeoutSeconds: options.playableTimeoutSeconds, sessionIsCurrent: backendIsCurrent)
            snapshots.append(controller.debugEvidenceSnapshot())
            let captureBackend = controller.debugEvidenceSnapshot().backend.rawValue
            await DebugPlaybackFrameCapture.captureIfRequested(from: controller.player, label: captureBackend + "-initial", log: log)
            guard backendIsCurrent() else { throw Blocked(reason: .backendChanged) }
            let priorItem = controller.player.currentItem
            var requiresReplacement = [.capped, .maximum].contains(scenario)
            var expectedAudio: PlaybackAudioTrack.ID?
            var expectedSubtitle: PlaybackSubtitleTrack.ID?
            switch scenario {
            case .seek:
                controller.performUserSeek(toMs: options.seekMs)
                let deadline = ContinuousClock.now.advanced(by: .seconds(options.playableTimeoutSeconds))
                while !seekTargetReached(positionSeconds: controller.player.currentTime().seconds, targetMs: options.seekMs),
                      ContinuousClock.now < deadline {
                    try Task.checkCancellation()
                    guard backendIsCurrent() else { throw Blocked(reason: .backendChanged) }
                    try await Task.sleep(for: .milliseconds(250))
                }
                guard seekTargetReached(positionSeconds: controller.player.currentTime().seconds, targetMs: options.seekMs) else {
                    throw Blocked(reason: .deadline)
                }
            case .capped: controller.reload(bitrateKbps: 8_000)
            case .maximum: controller.reload(bitrateKbps: StreamingQuality.maxTranscodedKbps)
            case .audio:
                // Metadata-owned and AVFoundation-owned choices have different authority.
                // Do not guess an index across a backend reload.
                if controller.supportsMetadataAudioSelection {
                    guard let snapshot = controller.loadAudioStreamChoices(),
                          let choice = snapshot.tracks.first(where: { $0.id != snapshot.selectedID }) else {
                        throw Blocked(reason: .unsupportedTrack)
                    }
                    await controller.selectAudioStream(choice)
                    expectedAudio = choice.id
                    requiresReplacement = true
                } else { throw Blocked(reason: .unsupportedTrack) }
            case .subtitles:
                let generation = controller.debugEvidenceSnapshot().generation
                let snapshot = try await controller.loadSubtitleTracks()
                try Task.checkCancellation()
                guard backendIsCurrent() else { throw Blocked(reason: .backendChanged) }
                guard controller.debugEvidenceSnapshot().generation == generation else { throw Blocked(reason: .staleGeneration) }
                guard let snapshot, let track = snapshot.tracks.first(where: {
                    $0.id != snapshot.selectedID && !controller.shouldConfirmSubtitleSelection($0, selectedID: snapshot.selectedID)
                }) else { throw Blocked(reason: .unsupportedTrack) }
                // Burn-risk choices are excluded; this does not grant a second approval.
                try await controller.selectSubtitle(track)
                expectedSubtitle = track.id
                requiresReplacement = subtitleRequiresReplacement(track.mechanism)
            default: break
            }
            if requiresReplacement {
                try await waitForReplacement(of: priorItem, player: controller.player,
                    timeoutSeconds: options.playableTimeoutSeconds,
                    sessionIsCurrent: backendIsCurrent,
                    playbackFailed: { controller.playbackError.isFailed },
                    consentPending: { controller.videoTranscodeConsent.isPending })
            }
            try await DebugPlaybackProbeSupport.waitUntilPlayable(controller, phase: "transition", timeoutSeconds: options.playableTimeoutSeconds, sessionIsCurrent: backendIsCurrent)
            try await DebugPlaybackProbeSupport.holdWithPlaybackProgress(controller,
                seconds: options.postSeekHoldSeconds, stallToleranceSeconds: options.stallToleranceSeconds, log: log,
                sessionIsCurrent: backendIsCurrent)
            guard backendIsCurrent() else { throw Blocked(reason: .backendChanged) }
            if let expectedAudio, controller.loadAudioStreamChoices()?.selectedID != expectedAudio {
                throw Blocked(reason: .decisionUnknown)
            }
            if let expectedSubtitle {
                let generation = controller.debugEvidenceSnapshot().generation
                let selected = try await controller.loadSubtitleTracks()?.selectedID
                guard backendIsCurrent(), controller.debugEvidenceSnapshot().generation == generation else {
                    throw Blocked(reason: .staleGeneration)
                }
                guard selected == expectedSubtitle else { throw Blocked(reason: .decisionUnknown) }
            }
            snapshots.append(controller.debugEvidenceSnapshot())
            if scenario == .original && controller.debugEvidenceSnapshot().videoDecision != .copy {
                throw Blocked(reason: .decisionUnknown)
            }
            if [.maximum, .consentApprove].contains(scenario) && controller.debugEvidenceSnapshot().videoDecision != .encode {
                throw Blocked(reason: .decisionUnknown)
            }
            await DebugPlaybackFrameCapture.captureIfRequested(from: controller.player, label: captureBackend + "-postseek", log: log)
            status = .passed; reason = .completed
        } catch let blocked as Blocked {
            // Capture the gate before stop() clears generation-scoped consent.
            snapshots.append(controller.debugEvidenceSnapshot())
            reason = blocked.reason
            throw blocked
        } catch is CancellationError {
            reason = .cancelled
            throw CancellationError()
        } catch {
            status = .failed; reason = .playbackFailed
            throw error
        }
    }
}
#endif
