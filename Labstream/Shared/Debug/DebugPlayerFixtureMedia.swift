#if DEBUG
import AVFoundation
import CoreVideo
import Foundation
import PMSKit

/// Generates the fixture's local video: 20 minutes of alternating solid frames, H.264, silent.
/// Written once into Caches and reused across launches.
enum DebugPlayerFixtureMedia {
    static var item: MediaItem {
        MediaItem(ratingKey: "tv-player-fixture", title: "TV Player Fixture", type: "movie",
                  duration: durationMs, year: 2026,
                  summary: "Deterministic local playback fixture for tvOS player chrome work.",
                  chapters: [
                      Chapter(id: 1, tag: "Opening", startTimeOffset: 0),
                      Chapter(id: 2, tag: "Middle", startTimeOffset: durationMs / 3),
                      Chapter(id: 3, tag: "Late", startTimeOffset: durationMs * 2 / 3),
                  ])
    }

    private static let durationSeconds = 1200
    private static var durationMs: Int { durationSeconds * 1000 }
    private static let frameDurationSeconds = 2
    private static let width = 1280
    private static let height = 720

    enum FixtureError: Error {
        case cachesUnavailable
        case pixelBufferUnavailable
        case writerFailed(String)
    }

    static func ensureVideoFile() async throws -> URL {
        guard let caches = FileManager.default.urls(for: .cachesDirectory,
                                                    in: .userDomainMask).first else {
            throw FixtureError.cachesUnavailable
        }
        let url = caches.appendingPathComponent("tv-player-fixture-\(durationSeconds)s.mp4")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let target = url
        try await Task.detached(priority: .userInitiated) {
            try writeVideo(to: target)
        }.value
        return url
    }

    private nonisolated static func writeVideo(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        writer.add(input)
        guard writer.startWriting() else {
            throw FixtureError.writerFailed(writer.error.map(String.init(describing:)) ?? "startWriting")
        }
        writer.startSession(atSourceTime: .zero)

        let frameCount = durationSeconds / frameDurationSeconds
        let frames = [try makeFrame(adaptor: adaptor, blue: 0x50, red: 0x10),
                      try makeFrame(adaptor: adaptor, blue: 0x18, red: 0x40)]
        var index = 0
        let deadline = Date().addingTimeInterval(60)
        while index < frameCount {
            guard Date() < deadline else { writer.cancelWriting(); throw FixtureError.writerFailed("timeout") }
            guard input.isReadyForMoreMediaData else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            let time = CMTime(value: CMTimeValue(index * frameDurationSeconds), timescale: 1)
            if !adaptor.append(frames[index % frames.count], withPresentationTime: time) {
                throw FixtureError.writerFailed(writer.error.map(String.init(describing:)) ?? "append")
            }
            index += 1
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        guard done.wait(timeout: .now() + 60) == .success else {
            writer.cancelWriting(); throw FixtureError.writerFailed("timeout")
        }
        if writer.status != .completed {
            throw FixtureError.writerFailed(writer.error.map(String.init(describing:)) ?? "finish")
        }
    }

    private nonisolated static func makeFrame(adaptor: AVAssetWriterInputPixelBufferAdaptor,
                                              blue: UInt8, red: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
              CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else {
            throw FixtureError.pixelBufferUnavailable
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw FixtureError.pixelBufferUnavailable
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let width = CVPixelBufferGetWidth(buffer)
        for row in 0..<height {
            let rowBase = base.advanced(by: row * bytesPerRow)
            let pixels = rowBase.assumingMemoryBound(to: UInt8.self)
            for column in 0..<width {
                let offset = column * 4
                pixels[offset] = blue
                pixels[offset + 1] = 0x20
                pixels[offset + 2] = red
                pixels[offset + 3] = 0xFF
            }
        }
        return buffer
    }
}
#endif
