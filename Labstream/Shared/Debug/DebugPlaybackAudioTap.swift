#if DEBUG && (os(visionOS) || os(macOS) || SIGNAL_LAB_HOST)
import AVFoundation
import Foundation
import MediaToolbox
import Synchronization

/// Preallocated, single-producer capture. The audio callback never writes files,
/// allocates sample buffers, waits for locks, or changes the supplied audio.
@available(visionOS 27, macOS 27, *)
nonisolated struct DebugPlaybackAudioTap: @unchecked Sendable {
    let tap: MTAudioProcessingTap
    private let postEffects: Bool
    private let storage: Storage
    static func supportsFormat(_ f: AudioStreamBasicDescription) -> Bool {
        let interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return f.mFormatID == kAudioFormatLinearPCM && f.mSampleRate == 48000
            && f.mChannelsPerFrame == 2 && f.mBitsPerChannel == 32
            && f.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && f.mFormatFlags & kAudioFormatFlagIsBigEndian == 0
            && f.mBytesPerFrame == (interleaved ? 8 : 4)
            && f.mFramesPerPacket == 1 && f.mBytesPerPacket == f.mBytesPerFrame
    }

    private struct Row {
        var pts: Double = 0
        var host: Double = 0
        var count: Int = 0
        var offset: Int = 0
        var flags: UInt32 = 0
        var epoch: Int = 0
    }

    /// Mutable cursors/format belong solely to prepare/process callbacks. Publication
    /// releases a completed immutable prefix; snapshot acquires only that prefix.
    private final class Storage: @unchecked Sendable {
        let samples = UnsafeMutablePointer<Float>.allocate(capacity: 48000 * 60 * 2)
        let rows = UnsafeMutablePointer<Row>.allocate(capacity: 8192)
        let published = Atomic<Int>(0)
        let overflow = Atomic<Bool>(false)
        let unsupported = Atomic<Bool>(false)
        let invalidTime = Atomic<Bool>(false)
        var used = 0
        var rowCount = 0
        var interleaved = false
        var validFormat = false
        var epoch = 0
        init() {
            samples.initialize(repeating: 0, count: 48000 * 60 * 2)
            rows.initialize(repeating: Row(), count: 8192)
        }
        deinit {
            samples.deinitialize(count: 48000 * 60 * 2); samples.deallocate()
            rows.deinitialize(count: 8192); rows.deallocate()
        }
    }

    init(postEffects: Bool = true) throws {
        let storage = Storage()
        let retained = Unmanaged.passRetained(storage)
        var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(), init: { _, client, output in output.pointee = client },
            finalize: { tap in
                Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            }, prepare: { tap, _, format in
                let state = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                let f = format.pointee
                state.interleaved = (f.mFormatFlags & kAudioFormatFlagIsNonInterleaved) == 0
                state.validFormat = DebugPlaybackAudioTap.supportsFormat(f)
                if !state.validFormat { state.unsupported.store(true, ordering: .relaxed) }
            }, unprepare: nil, process: { tap, requested, processFlags, buffers, count, flags in
                var range = CMTimeRange.invalid
                let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, &range, count)
                guard status == noErr, count.pointee > 0 else { return }
                let state = Unmanaged<Storage>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                guard state.validFormat else { return }
                let n = count.pointee
                guard n <= 48000 * 60 - state.used, state.rowCount < 8192 else {
                    state.overflow.store(true, ordering: .relaxed); return
                }
                let list = UnsafeMutableAudioBufferListPointer(buffers)
                guard list.count >= (state.interleaved ? 1 : 2),
                      list[0].mNumberChannels == (state.interleaved ? 2 : 1),
                      let left = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                if state.interleaved {
                    guard list[0].mDataByteSize >= n * 8 else { return }
                    state.samples.advanced(by: state.used * 2).update(from: left, count: n * 2)
                } else {
                    guard let right = list[1].mData?.assumingMemoryBound(to: Float.self),
                          list[1].mNumberChannels == 1,
                          list[0].mDataByteSize >= n * 4, list[1].mDataByteSize >= n * 4 else { return }
                    for i in 0..<n {
                        state.samples[(state.used+i)*2] = left[i]
                        state.samples[(state.used+i)*2+1] = right[i]
                    }
                }
                guard range.isValid, range.start.seconds.isFinite, range.duration.seconds.isFinite,
                      range.duration.seconds >= 0 else { state.invalidTime.store(true, ordering: .relaxed); return }
                let boundaryFlags = flags.pointee | processFlags
                if boundaryFlags & kMTAudioProcessingTapFlag_StartOfStream != 0 { state.epoch += 1 }
                state.rows[state.rowCount] = Row(pts: range.start.seconds, host: CACurrentMediaTime(),
                    count: n, offset: state.used * 8, flags: boundaryFlags, epoch: state.epoch)
                state.used += n
                state.rowCount += 1
                state.published.store(state.rowCount, ordering: .releasing)
            })
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        var output: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreateWithPreferredFormat(kCFAllocatorDefault, &callbacks,
            (postEffects ? kMTAudioProcessingTapCreationFlag_PostEffects : kMTAudioProcessingTapCreationFlag_PreEffects), format.formatDescription, &output)
        guard status == noErr, let output else {
            retained.release()
            throw NSError(domain: "SignalAudioTap", code: Int(status))
        }
        self.postEffects = postEffects
        self.tap = output
        self.storage = storage
    }

    @MainActor
    @discardableResult
    func attach(to item: AVPlayerItem, trackID: CMPersistentTrackID = 0) -> AVAudioMix {
        let parameters = AVMutableAudioMixInputParameters()
        parameters.trackID = trackID // Zero is OS-27 mixed output; exact asset track is a separate control.
        parameters.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [parameters]
        item.audioMix = mix
        // AVPlayerItem copies a mutable mix on assignment. Own the installed immutable copy.
        return item.audioMix!
    }

    @MainActor
    func installIfUnmixed(to item: AVPlayerItem, trackID: CMPersistentTrackID = 0) throws -> AVAudioMix {
        guard item.audioMix == nil else { throw NSError(domain: "SignalAudioTapConflict", code: 1) }
        return attach(to: item, trackID: trackID)
    }

    var publishedRows: Int { storage.published.load(ordering: .acquiring) }
    var streamEpoch: Int {
        let count = publishedRows
        return count == 0 ? 0 : storage.rows[count - 1].epoch
    }

    /// Snapshot only the published immutable prefix. The callback never locks or resets storage.
    func saveWindow(to directory: URL, startRow: Int, startHost: Double, endHost: Double,
                    startPTS: Double, endPTS: Double, requiredEpoch: Int,
                    runID: UUID, window: String) throws -> [String: Any] {
        let limit = publishedRows
        guard startRow >= 0, startRow <= limit, startPTS.isFinite, endPTS.isFinite,
              startHost.isFinite, endHost.isFinite, endHost >= startHost, endPTS >= startPTS else {
            throw NSError(domain: "SignalTapWindow", code: 1)
        }
        var selected: [Row] = []
        var raw = Data()
        var rows: [[String: Double]] = []
        var squares = [0.0, 0.0]
        var peak = 0.0
        for index in startRow..<limit {
            let row = storage.rows[index]
            guard row.host >= startHost, row.host <= endHost, row.epoch == requiredEpoch,
                  row.pts >= startPTS, row.pts < startPTS + 8 else { continue }
            selected.append(row)
            rows.append(["pts": row.pts, "host": row.host - startHost, "frames": Double(row.count),
                         "offset": Double(raw.count), "flags": Double(row.flags), "epoch": Double(row.epoch)])
            let first = storage.samples.advanced(by: row.offset / 4)
            raw.append(contentsOf: UnsafeRawBufferPointer(start: first, count: row.count * 8))
            for sample in 0..<row.count {
                for channel in 0..<2 {
                    let value = Double(first[sample * 2 + channel])
                    squares[channel] += value * value; peak = max(peak, abs(value))
                }
            }
        }
        let frames = selected.reduce(0) { $0 + $1.count }
        let gaps = zip(selected, selected.dropFirst()).map { abs($1.pts - ($0.pts + Double($0.count) / 48000)) }
        let stable = streamEpoch == requiredEpoch
        var summary: [String: Any] = ["schemaVersion": 1, "runID": runID.uuidString, "window": window,
            "audioBuffers": selected.count, "audioFrames": frames,
            "audioCoverage": "missing", "epochStable": stable, "streamEpoch": requiredEpoch,
            "startOfStreamRows": selected.filter { $0.flags & kMTAudioProcessingTapFlag_StartOfStream != 0 }.count,
            "overflow": storage.overflow.load(ordering: .relaxed), "unsupportedFormat": storage.unsupported.load(ordering: .relaxed),
            "invalidTime": storage.invalidTime.load(ordering: .relaxed), "qualityVerdict": "not-evaluated-no-reference",
            "scope": postEffects ? "post-effects-mix-not-speakers" : "pre-effects-mix-not-speakers"]
        if let first = selected.first, let last = selected.last {
            let final = last.pts + Double(last.count) / 48000
            summary["audioFirstPTS"] = first.pts; summary["audioLastEndPTS"] = final
            summary["audioAcquisitionDelaySeconds"] = first.pts - startPTS
            summary["audioMaxTimestampGapSeconds"] = gaps.max() ?? 0
            summary["audioRMSByChannel"] = squares.map { sqrt($0 / Double(frames)) }
            summary["audioPeak"] = peak
            summary["audioCoverage"] = stable && first.pts <= startPTS + 0.5 && final >= endPTS - 0.25 ? "captured" : "partial"
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Task.checkCancellation()
        try raw.write(to: directory.appendingPathComponent("tap.f32le"), options: .atomic)
        if streamEpoch != requiredEpoch { summary["epochStable"] = false; summary["audioCoverage"] = "partial" }
        let manifest: [String: Any] = ["schema": 1, "runID": runID.uuidString, "window": window,
            "scope": summary["scope"]!, "sampleRate": 48000, "requestedDurationSeconds": 8,
            "channels": 2, "rows": rows, "summary": summary, "initialPosition": startPTS, "position": endPTS]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("tap.json"), options: .atomic)
        return summary
    }

    func save(to directory: URL, startHostTime: Double) throws {
        let count = storage.published.load(ordering: .acquiring)
        let rows = (0..<count).map { index -> [String: Double] in
            let row = storage.rows[index]
            return ["pts": row.pts, "host": row.host - startHostTime,
                    "frames": Double(row.count), "offset": Double(row.offset),
                    "flags": Double(row.flags), "epoch": Double(row.epoch)]
        }
        let frames = count == 0 ? 0 : storage.rows[count-1].offset/8 + storage.rows[count-1].count
        try Data(bytes: storage.samples, count: frames * 8)
            .write(to: directory.appendingPathComponent("tap.f32le"), options: .atomic)
        let manifest: [String: Any] = ["schema": 1, "scope": postEffects ? "post-effects-mix-not-speakers" : "pre-effects-mix-not-speakers",
            "sampleRate": 48000, "channels": 2, "rows": rows,
            "overflow": storage.overflow.load(ordering: .relaxed),
            "unsupportedFormat": storage.unsupported.load(ordering: .relaxed)]
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("tap.json"), options: .atomic)
    }
}
#endif
