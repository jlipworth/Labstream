#if DEBUG
import AVFoundation
import Foundation
import os
#if os(macOS)
import AppKit
import AVKit
#endif

/// Plays an arbitrary HLS/media URL with a bare AVPlayer — no backend, no
/// PlaybackController — to isolate whether a playback failure is content/OS-level or
/// caused by the app's transport plumbing (headers, proxies, PMS URLs).
///
/// Inert unless launched with `--vp-probe-play-url <url>`. Logs status transitions, item
/// errors, and the AVPlayerItem error log, then runs the shared frame capture if
/// `--vp-probe-capture-frames` is present.
@MainActor
enum DebugRawURLPlaybackProbe {
    private static let log = Logger(subsystem: "org.labstream.Labstream", category: "RawURLProbe")

    static func runIfRequested() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let raw = DebugPlaybackProbeSupport.value(after: "--vp-probe-play-url", in: arguments),
              let url = URL(string: raw) else { return }

        if arguments.contains("--vp-probe-observer-control") {
            // Credential-free synthetic control only, never an arbitrary authenticated endpoint.
            guard url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
                  url.pathExtension.lowercased() == "m3u8", url.query == nil, url.user == nil,
                  url.password == nil else { log.error("probe.observer_control.invalid_url"); return }
        }
        if arguments.contains("--vp-probe-tap-control") {
            guard url.scheme == "http", ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
                  url.pathExtension.lowercased() == "mp4", url.query == nil, url.user == nil,
                  url.password == nil else { log.error("probe.tap_control.invalid_url"); return }
        }

        await run(url: url, headers: [:], arguments: arguments)
    }

    static func run(url: URL, headers: [String: String], arguments: [String]) async {
        log.notice("probe.start backend=rawurl")
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        let player = AVPlayer(playerItem: item)
        #if os(macOS)
        let view = AVPlayerView()
        view.player = player
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Playback diagnostic"
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        #endif
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        #if os(visionOS) || os(macOS)
        if let runID = DebugPlaybackProbeSupport.value(after: "--vp-probe-capture-signals", in: arguments) {
            if #available(visionOS 27, macOS 27, *) {
                do {
                    try await DebugPlaybackSignalCapture.run(url: url, headers: headers, runID: runID, captureAudioTap: arguments.contains("--vp-probe-audio-tap"))
                    log.notice("probe.signal_capture.complete")
                } catch {
                    log.error("probe.signal_capture.failed reason=\(String(describing: error), privacy: .public)")
                }
            } else {
                log.error("probe.signal_capture.unsupported_os")
            }
            return
        }
        #endif
        player.play()

        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if item.status == .failed { break }
            if item.status == .readyToPlay, player.rate > 0, item.currentTime().seconds > 1 { break }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .milliseconds(500))
        }

        if let rawID = DebugPlaybackProbeSupport.value(after: "--vp-probe-tap-control", in: arguments) {
            #if os(visionOS) || os(macOS)
            if #available(visionOS 27, macOS 27, *), let runID = UUID(uuidString: rawID),
               item.status == .readyToPlay, player.rate > 0, player.currentTime().seconds > 1 {
                do {
                    try await runTapControl(player: player, item: item, runID: runID,
                        mode: DebugPlaybackProbeSupport.value(after: "--vp-probe-tap-track", in: arguments) ?? "mixed")
                    log.notice("probe.tap_control.complete")
                } catch { log.error("probe.tap_control.failed") }
            } else { log.error("probe.tap_control.not_ready") }
            #endif
            return
        }

        if let rawID = DebugPlaybackProbeSupport.value(after: "--vp-probe-observer-control", in: arguments) {
            #if os(visionOS) || os(macOS)
            if #available(visionOS 27, macOS 27, *), let runID = UUID(uuidString: rawID),
               item.status == .readyToPlay, player.rate > 0, item.currentTime().seconds > 1 {
                do {
                    if arguments.contains("--vp-probe-observer-lifecycle") {
                        try await runObserverLifecycle(player: player, item: item, url: url, runID: runID)
                        log.notice("probe.observer_control.complete")
                        return
                    }
                    let retained = arguments.contains("--vp-probe-retain-observer-audio")
                        ? DebugPlaybackSignalCapture.RetainedAudioOutput(item: item) : nil
                    defer { retained?.close() }
                    for label in ["control-initial", "control-second"] {
                        let directory = URL.documentsDirectory.appendingPathComponent("ProbeSignalCaptures")
                            .appendingPathComponent(runID.uuidString).appendingPathComponent(label)
                        try await DebugPlaybackSignalCapture.observe(player: player, runID: runID.uuidString,
                                                                     directory: directory, retainedAudio: retained)
                    }
                    log.notice("probe.observer_control.complete")
                } catch { log.error("probe.observer_control.failed") }
            } else { log.error("probe.observer_control.not_ready") }
            #endif
            return
        }

        // Optional client-side seek (seconds) once initial playback is up — exercises the
        // PMS transcoder seek-restart on this lane without the offset= start param.
        if let seekSeconds = DebugPlaybackProbeSupport.intValue(after: "--vp-probe-rawurl-seek-s", in: arguments),
           item.status == .readyToPlay {
            log.notice("probe.rawurl seeking_to_s=\(seekSeconds, privacy: .public)")
            player.seek(to: CMTime(seconds: Double(seekSeconds), preferredTimescale: 600), completionHandler: { _ in })
            player.play()
            let seekDeadline = ContinuousClock.now.advanced(by: .seconds(120))
            let target = Double(seekSeconds)
            while ContinuousClock.now < seekDeadline {
                if item.status == .failed { break }
                if player.rate > 0, item.currentTime().seconds > target + 1 { break }
                if Task.isCancelled { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }

        log.notice("probe.rawurl status=\(item.status.rawValue, privacy: .public) rate=\(player.rate, privacy: .public) position_s=\(item.currentTime().seconds, privacy: .public)")
        if let error = item.error as NSError? {
            log.error("probe.rawurl item_error domain=\(error.domain, privacy: .public) code=\(error.code, privacy: .public)")
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                log.error("probe.rawurl underlying domain=\(underlying.domain, privacy: .public) code=\(underlying.code, privacy: .public)")
            }
        }
        if let errorLog = item.errorLog() {
            for event in errorLog.events.prefix(8) {
                log.error("probe.rawurl errlog status=\(event.errorStatusCode, privacy: .public)")
            }
        }
        for track in item.tracks {
            guard let assetTrack = track.assetTrack,
                  let descriptions = try? await assetTrack.load(.formatDescriptions) else { continue }
            for description in descriptions {
                let sub = CMFormatDescriptionGetMediaSubType(description)
                let bytes = [UInt8((sub >> 24) & 0xFF), UInt8((sub >> 16) & 0xFF), UInt8((sub >> 8) & 0xFF), UInt8(sub & 0xFF)]
                let codec = String(bytes: bytes, encoding: .ascii) ?? "?"
                log.notice("probe.rawurl track codec=\(codec, privacy: .public) enabled=\(track.isEnabled, privacy: .public)")
            }
        }
        await DebugPlaybackFrameCapture.captureIfRequested(from: player, label: "rawurl", log: log)
        let requiredPosition = Double(DebugPlaybackProbeSupport.intValue(after: "--vp-probe-rawurl-seek-s", in: arguments) ?? 0) + 1
        do {
            guard item.status == .readyToPlay, item.currentTime().seconds > requiredPosition else {
                throw DebugPlaybackProbeSupport.ProbeError.timeout("rawurl_start")
            }
            try await DebugPlaybackProbeSupport.holdWithPlaybackProgress(player: player,
                seconds: DebugPlaybackProbeSupport.intValue(after: "--vp-probe-post-seek-hold-seconds", in: arguments) ?? 15,
                stallToleranceSeconds: DebugPlaybackProbeSupport.intValue(after: "--vp-probe-stall-tolerance-seconds", in: arguments) ?? 20,
                log: log)
            log.notice("probe.pass sustained_progress=true")
        } catch {
            log.error("probe.fail error=rawurl_sustained_progress_unproven")
        }
    }

    #if os(visionOS) || os(macOS)
    @available(visionOS 27, macOS 27, *)
    private static func runTapControl(player: AVPlayer, item: AVPlayerItem, runID: UUID, mode: String) async throws {
        guard ["mixed", "asset"].contains(mode), item.audioMix == nil else {
            throw DebugPlaybackSignalCapture.CaptureError.invalidTime
        }
        var trackID: CMPersistentTrackID = 0
        if mode == "asset" {
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 1 else { throw DebugPlaybackSignalCapture.CaptureError.invalidTime }
            trackID = tracks[0].trackID
        }
        try Task.checkCancellation()
        guard player.currentItem === item else { throw DebugPlaybackSignalCapture.CaptureError.itemChanged }
        let tap = try DebugPlaybackAudioTap()
        let mix = try tap.installIfUnmixed(to: item, trackID: trackID)
        defer { if item.audioMix === mix { item.audioMix = nil } }
        let root = URL.documentsDirectory.appendingPathComponent("ProbeSignalCaptures").appendingPathComponent(runID.uuidString)
        func window(_ label: String, epoch: Int) async throws -> Bool {
            var publishedTap = false
            let directory = root.appendingPathComponent(label)
            defer { if !publishedTap { try? FileManager.default.removeItem(at: directory.appendingPathComponent("tap.json")) } }
            let firstRow = tap.publishedRows
            let startHost = CACurrentMediaTime()
            let startPTS = player.currentTime().seconds
            try await DebugPlaybackSignalCapture.observe(player: player, runID: runID.uuidString,
                directory: root.appendingPathComponent(label), captureDecodedAudio: false)
            try Task.checkCancellation()
            guard player.currentItem === item, item.audioMix === mix else {
                throw DebugPlaybackSignalCapture.CaptureError.itemChanged
            }
            var summary = try tap.saveWindow(to: root.appendingPathComponent(label), startRow: firstRow,
                startHost: startHost, endHost: CACurrentMediaTime(), startPTS: startPTS,
                endPTS: player.currentTime().seconds, requiredEpoch: epoch, runID: runID, window: label)
            summary.merge(["schemaVersion": 1, "runID": runID.uuidString, "window": label, "trackMode": mode,
                "requestedSeconds": 8, "observedSeconds": player.currentTime().seconds - startPTS]) { a, _ in a }
            try Task.checkCancellation()
            guard player.currentItem === item, item.audioMix === mix, tap.streamEpoch == epoch else {
                throw DebugPlaybackSignalCapture.CaptureError.sequenceChanged
            }
            DebugPlaybackEvidence.exportTapSummary(summary)
            publishedTap = true
            return summary["audioCoverage"] as? String == "captured" && summary["overflow"] as? Bool == false
                && summary["unsupportedFormat"] as? Bool == false && summary["invalidTime"] as? Bool == false
                && (summary["audioMaxTimestampGapSeconds"] as? Double ?? .infinity) <= 0.005
        }
        let startDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while tap.publishedRows == 0, ContinuousClock.now < startDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard try await window("tap-initial", epoch: tap.streamEpoch) else { return }
        for (label, target) in [("tap-forward", 18.0), ("tap-backward", 3.0)] {
            let before = tap.streamEpoch
            let completion = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero,
                        toleranceAfter: .zero) { done in completion.withLock { $0 = done } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            var reached = false
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                if completion.withLock({ $0 }) == true, abs(player.currentTime().seconds - target) < 1 { reached = true }
                if reached, tap.streamEpoch > before { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard reached, tap.streamEpoch > before else {
                DebugPlaybackEvidence.exportTapSummary(["schemaVersion": 1, "runID": runID.uuidString,
                    "window": label, "trackMode": mode, "outcome": "seekBoundaryBlocked", "clockReached": reached,
                    "preSeekEpoch": before, "streamEpoch": tap.streamEpoch])
                continue
            }
            _ = try await window(label, epoch: tap.streamEpoch)
        }
    }

    @available(visionOS 27, macOS 27, *)
    private static func lifecycleEvent(_ runID: UUID, _ stage: String, _ outcome: String,
                                       sequence: Int = -1, facts: [String: Any] = [:]) {
        var payload: [String: Any] = ["schemaVersion": 1, "runID": runID.uuidString,
            "stage": stage, "outcome": outcome, "audioSequenceGeneration": sequence]
        payload.merge(facts) { original, _ in original }
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            Logger(subsystem: "org.labstream.Labstream", category: "PlaybackEvidence")
                .notice("evidence.lifecycle payload=\(text, privacy: .public)")
        }
    }

    @available(visionOS 27, macOS 27, *)
    private static func settleSequence(_ owner: DebugPlaybackSignalCapture.RetainedAudioOutput) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var generation = owner.sequenceGeneration
        var stableSince = ContinuousClock.now
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
            let current = owner.sequenceGeneration
            if current != generation { generation = current; stableSince = .now }
            if ContinuousClock.now - stableSince >= .milliseconds(300) { return }
        }
        throw DebugPlaybackSignalCapture.CaptureError.sequenceChanged
    }

    @available(visionOS 27, macOS 27, *)
    private static func seekControl(_ player: AVPlayer,
        owner: DebugPlaybackSignalCapture.RetainedAudioOutput, to seconds: Double,
        runID: UUID, stage: String) async throws -> Bool {
        let before = owner.sequenceGeneration
        let completion = OSAllocatedUnfairLock<Bool?>(initialState: nil)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero,
                    toleranceAfter: .zero) { finished in completion.withLock { $0 = finished } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        var targetReached = false
        var quarantined = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if completion.withLock({ $0 }) == true,
               player.currentTime().seconds.isFinite, abs(player.currentTime().seconds - seconds) < 1 {
                targetReached = true
            }
            if completion.withLock({ $0 }) == true, owner.sequenceGeneration > before, targetReached {
                try await settleSequence(owner)
                lifecycleEvent(runID, stage, "seekRestartAcknowledged", sequence: owner.sequenceGeneration,
                    facts: ["quarantinedBuffers": quarantined, "seekCompletion": "completed", "clock": "targetReached",
                            "delegateSelectorAvailable": owner.delegateSelectorAvailable])
                return true
            }
            // Some outputs announce restart only when pulling resumes. All such samples
            // are quarantined, never admitted to a capture, until the SDK epoch advances.
            if owner.sequenceGeneration == before {
                do { if try owner.nextSample(expectedSequence: before) != nil { quarantined += 1 } }
                catch DebugPlaybackSignalCapture.CaptureError.sequenceChanged { /* callback raced this pull */ }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let completed = completion.withLock { $0 }
        lifecycleEvent(runID, stage, "seekRestartBlocked", sequence: owner.sequenceGeneration,
            facts: ["quarantinedBuffers": quarantined, "seekCompletion": completed == nil ? "pending" : completed! ? "completed" : "cancelled",
                    "clock": targetReached ? "targetReached" : "notReached", "preSeekGeneration": before,
                    "delegateSelectorAvailable": owner.delegateSelectorAvailable])
        return false
    }

    @available(visionOS 27, macOS 27, *)
    private static func runObserverLifecycle(player: AVPlayer, item: AVPlayerItem, url: URL,
                                             runID: UUID) async throws {
        let root = URL.documentsDirectory.appendingPathComponent("ProbeSignalCaptures")
            .appendingPathComponent(runID.uuidString)
        let owner = DebugPlaybackSignalCapture.RetainedAudioOutput(item: item)
        defer { owner.close() }
        try await settleSequence(owner)
        lifecycleEvent(runID, "initialSequence", "stable", sequence: owner.sequenceGeneration,
                       facts: ["delegateSelectorAvailable": owner.delegateSelectorAvailable])
        try await DebugPlaybackSignalCapture.observe(player: player, runID: runID.uuidString,
            directory: root.appendingPathComponent("control-initial"), retainedAudio: owner)
        var seekFailures = 0
        for (stage, target) in [("control-forward", 18.0), ("control-backward", 3.0)] {
            lifecycleEvent(runID, stage, "seekIssued", sequence: owner.sequenceGeneration)
            if try await seekControl(player, owner: owner, to: target, runID: runID, stage: stage) {
                do {
                    try await DebugPlaybackSignalCapture.observe(player: player, runID: runID.uuidString,
                        directory: root.appendingPathComponent(stage), retainedAudio: owner)
                } catch is CancellationError { throw CancellationError() }
                catch { seekFailures += 1; lifecycleEvent(runID, stage, "captureInvalidated") }
            } else { seekFailures += 1 }
        }
        let replacement = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: replacement)
        player.play()
        do {
            try await DebugPlaybackSignalCapture.observe(player: player, runID: runID.uuidString,
                directory: root.appendingPathComponent("control-rejected"), retainedAudio: owner)
            throw DebugPlaybackSignalCapture.CaptureError.invalidTime
        } catch DebugPlaybackSignalCapture.CaptureError.itemChanged {
            lifecycleEvent(runID, "itemReplacement", "oldOwnerRejected")
        }
        owner.close()
        guard !item.outputs.contains(where: { $0 === owner.output }) else {
            throw DebugPlaybackSignalCapture.CaptureError.itemChanged
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if replacement.status == .readyToPlay, player.rate > 0, player.currentTime().seconds > 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard replacement.status == .readyToPlay, player.rate > 0,
              player.currentTime().seconds.isFinite, player.currentTime().seconds > 1 else {
            throw DebugPlaybackSignalCapture.CaptureError.itemChanged
        }
        let nextOwner = DebugPlaybackSignalCapture.RetainedAudioOutput(item: replacement)
        defer { nextOwner.close() }
        try await settleSequence(nextOwner)
        try await DebugPlaybackSignalCapture.observe(player: player, runID: runID.uuidString,
            directory: root.appendingPathComponent("control-replacement"), retainedAudio: nextOwner)
        let cancelledDirectory = root.appendingPathComponent("control-cancelled")
        let observation = Task {
            try await DebugPlaybackSignalCapture.observe(player: player, runID: runID.uuidString,
                directory: cancelledDirectory, retainedAudio: nextOwner)
        }
        defer { observation.cancel() }
        try await Task.sleep(for: .milliseconds(500))
        observation.cancel()
        do {
            try await observation.value
            throw DebugPlaybackSignalCapture.CaptureError.invalidTime
        } catch is CancellationError {
            nextOwner.close()
            guard !replacement.outputs.contains(where: { $0 === nextOwner.output }),
                  !replacement.outputs.contains(where: { $0 is AVPlayerItemVideoOutput }),
                  !FileManager.default.fileExists(atPath: cancelledDirectory.appendingPathComponent("capture.json").path)
            else { throw DebugPlaybackSignalCapture.CaptureError.invalidTime }
            lifecycleEvent(runID, "cancellation", "cancelledNoManifestOutputDetached")
        }
        lifecycleEvent(runID, "result", seekFailures == 0 ? "allLifecyclePhasesCompleted" : "seekLifecycleBlocked",
                       facts: ["seekFailures": seekFailures])
    }
    #endif
}
#endif
