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
        player.play()

        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while ContinuousClock.now < deadline {
            if item.status == .failed { break }
            if item.status == .readyToPlay, player.rate > 0, item.currentTime().seconds > 1 { break }
            try? await Task.sleep(for: .milliseconds(500))
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
                log.error("probe.rawurl errlog status=\(event.errorStatusCode, privacy: .public) domain=\(event.errorDomain, privacy: .public) comment=\(event.errorComment ?? "-", privacy: .public)")
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
        let passed = item.status == .readyToPlay && item.currentTime().seconds > requiredPosition
        if passed {
            log.notice("probe.pass position_ms=\(Int(item.currentTime().seconds * 1000), privacy: .public) failed=false")
        } else {
            log.error("probe.fail error=rawurl_did_not_play")
        }
        if passed { try? await Task.sleep(for: .seconds(15)) }
        player.pause()
    }
}
#endif
