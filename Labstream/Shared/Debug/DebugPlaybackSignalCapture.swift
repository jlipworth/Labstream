#if DEBUG && (os(visionOS) || os(macOS) || SIGNAL_LAB_HOST)
import AVFoundation
import Foundation
import os

/// Bounded OS-27 feasibility probe. Captures decoded signals, not physical output.
@available(visionOS 27, macOS 27, *)
enum DebugPlaybackSignalCapture {
    /// Experimental control owner: exactly one output/item, with explicit bounded lifetime.
    nonisolated final class RetainedAudioOutput: NSObject, __AVPlayerItemSampleBufferOutputDelegate, @unchecked Sendable {
        let item: AVPlayerItem
        let output: AVPlayerItemSampleBufferOutput
        private let lock = NSLock()
        private var attached = true
        private var deferredSample: CMSampleBuffer?
        private var sequence = 0
        var sequenceGeneration: Int { lock.withLock { sequence } }
        var delegateSelectorAvailable: Bool {
            responds(to: #selector(outputSequenceWasRestarted(_:))) && output.__delegate === self
        }
        init(item: AVPlayerItem) {
            self.item = item
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_Stereo)!
            let config = AVPlayerItemSampleBufferOutputAudioConfiguration()
            config.requestedAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 48000,
                                                       channelLayout: layout).formatDescription
            output = AVPlayerItemSampleBufferOutput(configuration: config)
            super.init()
            output.__setDelegate(self, queue: DispatchQueue(label: "org.labstream.observer.sequence"))
            item.add(output)
        }
        /// SDK contract: this callback commences a new sequence after seeks/direction changes.
        /// Serialize it with sample pulls; a raced pull invalidates its entire capture window.
        @objc func outputSequenceWasRestarted(_ output: AVPlayerItemSampleBufferOutput) {
            lock.withLock {
                guard attached, output === self.output else { return }
                sequence += 1
                deferredSample = nil
            }
        }
        func requireSequence(_ expected: Int) throws {
            try lock.withLock {
                guard attached, sequence == expected else { throw CaptureError.sequenceChanged }
            }
        }
        func isActive(for candidate: AVPlayerItem) -> Bool {
            lock.withLock { attached && item === candidate }
        }
        func close() {
            let remove = lock.withLock {
                deferredSample = nil
                let remove = attached
                attached = false
                return remove
            }
            if remove { output.__setDelegate(nil, queue: nil); item.remove(output) }
        }
        func nextSample(expectedSequence: Int) throws -> CMSampleBuffer? {
            try lock.withLock {
                guard attached, sequence == expectedSequence else { throw CaptureError.sequenceChanged }
                if let sample = deferredSample { deferredSample = nil; return sample }
                return output.__copyNextSampleBuffer()
            }
        }
        func deferFutureSample(_ sample: CMSampleBuffer, expectedSequence: Int) throws {
            try lock.withLock {
                guard attached, sequence == expectedSequence else { throw CaptureError.sequenceChanged }
                guard deferredSample == nil else { throw CaptureError.invalidTime }
                deferredSample = sample
            }
        }
        deinit { close() }
    }

    nonisolated static func sampleStartsInObservationWindow(_ pts: Double, start: Double, duration: Double) -> Bool {
        pts.isFinite && start.isFinite && duration.isFinite && duration > 0 && pts >= start && pts < start + duration
    }
    @concurrent
    nonisolated static func run(url: URL, headers: [String: String], runID: String, captureAudioTap: Bool = false, tapPostEffects: Bool = true, pitchAlgorithm: String? = nil, captureDecodedAudio: Bool = true, requestedChannels: Int = 2,
                               directory: URL = URL.documentsDirectory.appendingPathComponent("SignalCaptures")) async throws {
        let options: [String: Any]? = headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let item = AVPlayerItem(asset: AVURLAsset(url: url, options: options))
        if pitchAlgorithm == "varispeed" {
            await MainActor.run { item.audioTimePitchAlgorithm = .varispeed }
        }
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        try await capture(player: player, item: item, runID: runID, directory: directory,
                          managesPlayback: true, captureAudioTap: captureAudioTap,
                          tapPostEffects: tapPostEffects, pitchAlgorithm: pitchAlgorithm,
                          captureDecodedAudio: captureDecodedAudio, requestedChannels: requestedChannels, durationSeconds: 10)
    }

    /// Observe the application's existing item without starting, pausing, seeking or replacing it.
    @concurrent
    nonisolated static func observe(player: AVPlayer, runID: String, directory: URL,
                                   retainedAudio: RetainedAudioOutput? = nil,
                                   captureDecodedAudio: Bool = true) async throws {
        guard let item = player.currentItem else { throw CaptureError.itemChanged }
        if let retainedAudio, !retainedAudio.isActive(for: item) { throw CaptureError.itemChanged }
        try await capture(player: player, item: item, runID: runID, directory: directory,
                          managesPlayback: false, captureAudioTap: false, tapPostEffects: true,
                          pitchAlgorithm: nil, captureDecodedAudio: captureDecodedAudio, requestedChannels: 2, durationSeconds: 8,
                          retainedAudio: retainedAudio)
    }

    #if !SIGNAL_LAB_HOST
    /// Explicit DEBUG backend measurement. Refuses existing effects and restores only its own mix.
    @MainActor static func observeTapWindow(player: AVPlayer, runID: UUID, directory: URL,
                                            label: String, mode: String) async throws {
        guard let item = player.currentItem, item.audioMix == nil, ["mixed", "asset"].contains(mode) else {
            throw CaptureError.invalidTime
        }
        var trackID: CMPersistentTrackID = 0
        if mode == "asset" {
            let tracks = try await item.asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 1 else { throw CaptureError.unsupportedPCM }
            trackID = tracks[0].trackID
        }
        try Task.checkCancellation()
        guard player.currentItem === item else { throw CaptureError.itemChanged }
        let tap = try DebugPlaybackAudioTap()
        let mix = try tap.installIfUnmixed(to: item, trackID: trackID)
        var publishedTap = false
        defer {
            if item.audioMix === mix { item.audioMix = nil }
            if !publishedTap { try? FileManager.default.removeItem(at: directory.appendingPathComponent("tap.json")) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while tap.publishedRows == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let epoch = tap.streamEpoch
        let firstRow = tap.publishedRows
        let startHost = CACurrentMediaTime()
        let startPTS = player.currentTime().seconds
        try await observe(player: player, runID: runID.uuidString, directory: directory, captureDecodedAudio: false)
        try Task.checkCancellation()
        guard player.currentItem === item, item.audioMix === mix else { throw CaptureError.itemChanged }
        var summary = try tap.saveWindow(to: directory, startRow: firstRow, startHost: startHost,
            endHost: CACurrentMediaTime(), startPTS: startPTS, endPTS: player.currentTime().seconds,
            requiredEpoch: epoch, runID: runID, window: label)
        summary.merge(["schemaVersion": 1, "runID": runID.uuidString, "window": label, "trackMode": mode,
            "requestedSeconds": 8, "observedSeconds": player.currentTime().seconds - startPTS]) { a, _ in a }
        try Task.checkCancellation()
        guard player.currentItem === item, item.audioMix === mix, tap.streamEpoch == epoch else {
            throw CaptureError.sequenceChanged
        }
        DebugPlaybackEvidence.exportTapSummary(summary)
        publishedTap = true
    }
    #endif

    @concurrent
    nonisolated private static func capture(player: AVPlayer, item: AVPlayerItem, runID: String,
        directory: URL, managesPlayback: Bool, captureAudioTap: Bool, tapPostEffects: Bool,
        pitchAlgorithm: String?, captureDecodedAudio: Bool, requestedChannels: Int, durationSeconds: Double,
        retainedAudio: RetainedAudioOutput? = nil) async throws {
        guard [2, 6].contains(requestedChannels) else { throw CaptureError.unsupportedPCM }
        func failure(_ stage: String) -> CaptureError {
            var codes = [String]()
            var error = item.error as NSError?
            for _ in 0..<3 {
                guard let current = error else { break }
                codes.append("\(current.domain):\(current.code)")
                error = current.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            return .playerFailed("\(stage) status=\(item.status.rawValue) errors=\(codes.joined(separator: ","))")
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var published = false
        defer {
            if !published { try? FileManager.default.removeItem(at: directory.appendingPathComponent("capture.json")) }
        }
        let layout = AVAudioChannelLayout(layoutTag: requestedChannels == 6
            ? kAudioChannelLayoutTag_MPEG_5_1_A : kAudioChannelLayoutTag_Stereo)!
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
        let configuration = AVPlayerItemSampleBufferOutputAudioConfiguration()
        configuration.requestedAudioFormat = format.formatDescription
        let audio = retainedAudio?.output ?? AVPlayerItemSampleBufferOutput(configuration: configuration)
        let video = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVImageBufferColorPrimariesKey as String: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
            kCVImageBufferTransferFunctionKey as String: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
            kCVImageBufferYCbCrMatrixKey as String: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String
        ])
        if captureDecodedAudio && retainedAudio == nil { item.add(audio) }
        item.add(video)
        defer { if captureDecodedAudio && retainedAudio == nil { item.remove(audio) }; item.remove(video) }
        let tapCapture = captureAudioTap ? try DebugPlaybackAudioTap(postEffects: tapPostEffects) : nil
        await MainActor.run { if let tapCapture { _ = tapCapture.attach(to: item) } }
        var observedLayouts = Set<UInt32>()
        var audioRows: [[String: Double]] = []
        var videoRows: [[String: Double]] = []
        var audioBytes = Data()
        var videoBytes = Data()
        var audioEnd = -Double.infinity
        var lastVideo = -Double.infinity
        // Prepare decoding before starting the clock; pulling the first samples only
        // after play() can omit startup audio on the simulator's OS-27 output path.
        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while item.status == .unknown, ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard item.status == .readyToPlay else { throw failure("ready_deadline") }
        if managesPlayback {
            let prepared = await player.preroll(atRate: 1)
            guard prepared else { throw failure("preroll") }
        }
        let initialPosition = item.currentTime().seconds
        guard initialPosition.isFinite else { throw CaptureError.invalidTime }
        let audioSequence = retainedAudio?.sequenceGeneration
        let start = CACurrentMediaTime()
        var started = false
        while CACurrentMediaTime() - start < 25 {
            try Task.checkCancellation()
            guard player.currentItem === item else { throw CaptureError.itemChanged }
            if let retainedAudio, let audioSequence { try retainedAudio.requireSequence(audioSequence) }
            if item.status == .failed { throw failure("playback") }
            let position = item.currentTime().seconds
            if position >= initialPosition + durationSeconds { break }
            // Bound look-ahead and work. Sample arrival is NOT output timing.
            let audioLookAhead = retainedAudio == nil ? position + 0.25
                : min(position + 0.25, initialPosition + durationSeconds)
            for _ in 0..<8 where captureDecodedAudio && audioEnd < audioLookAhead {
                let nextSample: CMSampleBuffer?
                if let retainedAudio, let audioSequence {
                    nextSample = try retainedAudio.nextSample(expectedSequence: audioSequence)
                }
                else { nextSample = audio.__copyNextSampleBuffer() }
                guard let sample = nextSample else { break }
                let count = CMSampleBufferGetNumSamples(sample)
                guard count > 0 else { continue }
                let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
                guard pts.isFinite else { throw CaptureError.invalidTime }
                if let retainedAudio, !sampleStartsInObservationWindow(pts, start: initialPosition,
                                                                      duration: durationSeconds) {
                    if pts < initialPosition { continue }
                    try retainedAudio.deferFutureSample(sample, expectedSequence: audioSequence!)
                    audioEnd = pts
                    break
                }
                guard let description = CMSampleBufferGetFormatDescription(sample) else {
                    throw CaptureError.unsupportedPCM
                }
                // Some OS-27 multichannel descriptions contain valid LPCM ASBDs but
                // AVAudioFormat(formatDescription:) rejects their layout metadata. Validate
                // the bytes directly and copy to our explicit requested planar format.
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                      asbd.mFormatID == kAudioFormatLinearPCM, asbd.mChannelsPerFrame == requestedChannels,
                      asbd.mSampleRate == 48000, asbd.mBitsPerChannel == 32,
                      asbd.mBytesPerFrame == 4,
                      asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                      asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0,
                      asbd.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))
                else { throw CaptureError.unexpectedPCM("subtype=\(CMFormatDescriptionGetMediaSubType(description)) requestedChannels=\(requestedChannels)") }
                if let channelLayout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: nil) {
                    observedLayouts.insert(channelLayout.pointee.mChannelLayoutTag)
                }
                buffer.frameLength = AVAudioFrameCount(count)
                let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
                    frameCount: Int32(count), into: buffer.mutableAudioBufferList)
                guard status == noErr, let channels = buffer.floatChannelData else {
                    throw CaptureError.unsupportedPCM
                }
                var audioRow: [String: Double] = ["pts": pts, "host": CACurrentMediaTime() - start,
                    "player": position, "frames": Double(count), "offset": Double(audioBytes.count)]
                for (key, value) in [("inputPTS", CMSampleBufferGetPresentationTimeStamp(sample).seconds),
                                     ("inputDuration", CMSampleBufferGetDuration(sample).seconds),
                                     ("outputDuration", CMSampleBufferGetOutputDuration(sample).seconds)] where value.isFinite {
                    audioRow[key] = value
                }
                for (name, key) in [("trimStart", kCMSampleBufferAttachmentKey_TrimDurationAtStart),
                                    ("trimEnd", kCMSampleBufferAttachmentKey_TrimDurationAtEnd)] {
                    if let dictionary = CMGetAttachment(sample, key: key, attachmentModeOut: nil) as? [String: Any] {
                        let seconds = CMTimeMakeFromDictionary(dictionary as CFDictionary).seconds
                        if seconds.isFinite { audioRow[name] = seconds }
                    }
                }
                audioRows.append(audioRow)
                for index in 0..<count {
                    for channel in 0..<requestedChannels {
                        var value = channels[channel][index]
                        withUnsafeBytes(of: &value) { audioBytes.append(contentsOf: $0) }
                    }
                }
                audioEnd = pts + Double(count) / 48000
            }
            let requested = video.itemTime(forHostTime: CACurrentMediaTime())
            var displayed = CMTime.invalid
            if video.hasNewPixelBuffer(forItemTime: requested),
               let pixel = video.copyPixelBuffer(forItemTime: requested, itemTimeForDisplay: &displayed),
               displayed.seconds.isFinite, displayed.seconds > lastVideo {
                // Direct nearest-neighbor copy avoids Core Image's expensive first-use
                // compilation blocking the player observer and losing early frames.
                guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else {
                    throw CaptureError.unsupportedPixels
                }
                defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(pixel),
                      CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else {
                    throw CaptureError.unsupportedPixels
                }
                let width = CVPixelBufferGetWidth(pixel)
                let height = CVPixelBufferGetHeight(pixel)
                let stride = CVPixelBufferGetBytesPerRow(pixel)
                let source = base.assumingMemoryBound(to: UInt8.self)
                var bytes = [UInt8](repeating: 255, count: 160 * 90 * 4)
                for y in 0..<90 {
                    for x in 0..<160 {
                        let src = (y * height / 90) * stride + (x * width / 160) * 4
                        let dst = (y * 160 + x) * 4
                        bytes[dst] = source[src + 2]
                        bytes[dst + 1] = source[src + 1]
                        bytes[dst + 2] = source[src]
                    }
                }
                videoRows.append(["pts": displayed.seconds, "host": CACurrentMediaTime() - start,
                    "player": position, "offset": Double(videoBytes.count)])
                videoBytes.append(contentsOf: bytes)
                lastVideo = displayed.seconds
            }
            if managesPlayback && !started {
                player.play()
                started = true
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        if managesPlayback { player.pause() }
        if let retainedAudio, let audioSequence { try retainedAudio.requireSequence(audioSequence) }
        if captureAudioTap { await MainActor.run { item.audioMix = nil } }
        try tapCapture?.save(to: directory, startHostTime: start)
        try audioBytes.write(to: directory.appendingPathComponent("audio.f32le"), options: .atomic)
        try videoBytes.write(to: directory.appendingPathComponent("video.rgba"), options: .atomic)
        try Task.checkCancellation()
        guard player.currentItem === item else { throw CaptureError.itemChanged }
        if let retainedAudio, let audioSequence { try retainedAudio.requireSequence(audioSequence) }
        let result: [String: Any] = ["schema": 1, "runID": runID,
            "scope": "decoded-signals-not-device-output", "pitchAlgorithm": pitchAlgorithm ?? "default", "audio": audioRows, "video": videoRows,
            "position": item.currentTime().seconds, "wallSeconds": CACurrentMediaTime() - start,
            "requestedDurationSeconds": durationSeconds, "observedChannelLayoutTags": observedLayouts.sorted(),
            "initialPosition": initialPosition, "managesPlayback": managesPlayback,
            "retainedAudioOutput": retainedAudio != nil,
            "audioSequenceGeneration": audioSequence ?? -1, "audioSequenceStable": true,
            "requestedChannelLayoutTag": layout.layoutTag,
            "sampleRate": 48000, "channels": requestedChannels, "width": 160, "height": 90]
        try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("capture.json"), options: .atomic)
        // Intended bounded evidence only. Raw samples and media identities stay in the sandbox.
        let labels = ["control-initial", "control-second", "control-forward", "control-backward", "control-replacement", "tap-initial", "tap-forward", "tap-backward", "plex-initial", "plex-postseek",
                      "jellyfin-initial", "jellyfin-postseek", "emby-initial", "emby-postseek"]
        if !managesPlayback, UUID(uuidString: runID) != nil, labels.contains(directory.lastPathComponent) {
            let times = videoRows.compactMap { $0["pts"] }
            let maxGap = zip(times, times.dropFirst()).map { $1 - $0 }.max() ?? 0
            var summary: [String: Any] = ["schemaVersion": 1, "runID": runID,
                "window": directory.lastPathComponent, "audioBuffers": audioRows.count,
                "videoBuffers": videoRows.count, "videoMaxTimestampGapSeconds": maxGap,
                "observedSeconds": item.currentTime().seconds - initialPosition,
                "requestedSeconds": durationSeconds, "retainedAudioOutput": retainedAudio != nil,
                "audioSequenceGeneration": audioSequence ?? -1, "audioSequenceStable": true,
                "audioCoverage": "missing", "qualityVerdict": "not-evaluated-no-reference"]
            if let first = audioRows.first, let last = audioRows.last,
               let firstPTS = first["pts"], let lastPTS = last["pts"], let frames = last["frames"] {
                let endPTS = lastPTS + frames / 48000
                let audioGaps = zip(audioRows, audioRows.dropFirst()).map { before, after in
                    abs(after["pts"]! - (before["pts"]! + before["frames"]! / 48000))
                }
                summary["audioFirstPTS"] = firstPTS
                summary["audioLastEndPTS"] = endPTS
                summary["audioAcquisitionDelaySeconds"] = firstPTS - initialPosition
                summary["audioMaxTimestampGapSeconds"] = audioGaps.max() ?? 0
                summary["audioCoverage"] = firstPTS <= initialPosition + 0.5 &&
                    endPTS >= item.currentTime().seconds - 0.25 ? "captured" : "partial"
            }
            let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
            if let payload = String(data: data, encoding: .utf8), data.count <= 1024 {
                try Task.checkCancellation()
                guard player.currentItem === item else { throw CaptureError.itemChanged }
                if let retainedAudio, let audioSequence { try retainedAudio.requireSequence(audioSequence) }
                Logger(subsystem: "org.labstream.Labstream", category: "PlaybackEvidence")
                    .notice("evidence.observation payload=\(payload, privacy: .public)")
            }
        }
        published = true
    }

    enum CaptureError: Error { case playerFailed(String), unsupportedPCM, unexpectedPCM(String), unsupportedPixels, invalidTime, itemChanged, sequenceChanged }
}
#endif
