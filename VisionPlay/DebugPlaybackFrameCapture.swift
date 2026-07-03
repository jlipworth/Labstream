#if DEBUG
import AVFoundation
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Opt-in frame capture for the DEBUG playback probes (`--vp-probe-capture-frames`).
///
/// The probes verify transport (readyToPlay, playhead advance, stalls) but are blind to
/// what the decoder actually renders — a DV P5 green/purple tint or an all-black feed
/// sails straight through `probe.pass`. This taps the SAME `AVPlayerItem` the probe is
/// playing via `AVPlayerItemVideoOutput`, so the frames written are exactly what AVPlayer
/// decoded (post video-toolbox, pre display) — no simulator screen recording, no UI
/// driving. Each sampled frame is:
///   - written as a PNG under `Documents/ProbeCaptures/<label>/` in the app container
///     (pull with `simctl get_app_container` and read the images directly), and
///   - summarized in the log as public average RGB + luma, so black-screen
///     (luma ≈ 0) and strong tint (channel skew) are greppable without pulling files.
@MainActor
enum DebugPlaybackFrameCapture {
    static let flag = "--vp-probe-capture-frames"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    /// Samples `count` frames `intervalSeconds` apart from the player's current item.
    /// No-op unless launched with `--vp-probe-capture-frames`. Never throws — capture
    /// problems must not fail the transport probe; they are logged instead.
    static func captureIfRequested(from player: AVPlayer,
                                   label: String,
                                   count: Int = 4,
                                   intervalSeconds: Double = 2,
                                   log: Logger) async {
        guard isRequested else { return }
        guard let item = player.currentItem else {
            log.error("probe.frame_capture.fail label=\(label, privacy: .public) reason=no_current_item")
            return
        }

        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        defer { item.remove(output) }

        guard let directory = captureDirectory(label: label, log: log) else { return }
        let context = CIContext()
        var written = 0

        for index in 0..<count {
            try? await Task.sleep(for: .milliseconds(Int(intervalSeconds * 1000)))
            let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
            guard output.hasNewPixelBuffer(forItemTime: itemTime),
                  let pixelBuffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
                log.notice("probe.frame index=\(index, privacy: .public) label=\(label, privacy: .public) status=no_new_pixel_buffer")
                continue
            }

            let image = CIImage(cvPixelBuffer: pixelBuffer)
            if let average = averageRGB(of: image, context: context) {
                let luma = 0.2126 * average.r + 0.7152 * average.g + 0.0722 * average.b
                log.notice("probe.frame index=\(index, privacy: .public) label=\(label, privacy: .public) avg_r=\(Int(average.r), privacy: .public) avg_g=\(Int(average.g), privacy: .public) avg_b=\(Int(average.b), privacy: .public) luma=\(Int(luma), privacy: .public)")
            }

            let fileURL = directory.appendingPathComponent(String(format: "frame-%02d.png", index))
            if writePNG(image, scaledToMaxWidth: 960, to: fileURL, context: context) {
                written += 1
            } else {
                log.error("probe.frame_capture.fail label=\(label, privacy: .public) index=\(index, privacy: .public) reason=png_write_failed")
            }
        }

        log.notice("probe.frame_capture.done label=\(label, privacy: .public) written=\(written, privacy: .public) of=\(count, privacy: .public) dir=ProbeCaptures/\(label, privacy: .public)")
    }

    private static func captureDirectory(label: String, log: Logger) -> URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            log.error("probe.frame_capture.fail label=\(label, privacy: .public) reason=no_documents_dir")
            return nil
        }
        let directory = documents.appendingPathComponent("ProbeCaptures", isDirectory: true)
            .appendingPathComponent(label, isDirectory: true)
        do {
            // Fresh directory per run so stale frames from an earlier probe can't be
            // mistaken for this run's output.
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            log.error("probe.frame_capture.fail label=\(label, privacy: .public) reason=mkdir_failed")
            return nil
        }
    }

    private static func averageRGB(of image: CIImage, context: CIContext) -> (r: Double, g: Double, b: Double)? {
        let extent = image.extent
        guard !extent.isInfinite, extent.width > 0, extent.height > 0 else { return nil }
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image,
            kCIInputExtentKey: CIVector(cgRect: extent),
        ]), let averaged = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(averaged,
                       toBitmap: &pixel,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .BGRA8,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        return (r: Double(pixel[2]), g: Double(pixel[1]), b: Double(pixel[0]))
    }

    private static func writePNG(_ image: CIImage,
                                 scaledToMaxWidth maxWidth: CGFloat,
                                 to url: URL,
                                 context: CIContext) -> Bool {
        var output = image
        if image.extent.width > maxWidth {
            let scale = maxWidth / image.extent.width
            output = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return false }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                UTType.png.identifier as CFString,
                                                                1,
                                                                nil) else { return false }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination)
    }
}
#endif
