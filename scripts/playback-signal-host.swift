import AppKit
import AVFoundation
import Foundation

/// A run-loop host for the same experimental capture implementation used by visionOS.
/// No LabstreamMac session, player UI, or production identity is involved.
@main
@MainActor
struct PlaybackSignalHost {
    static func main() {
        guard CommandLine.arguments.count == 4,
              let url = URL(string: CommandLine.arguments[1]),
              !FileManager.default.fileExists(atPath: CommandLine.arguments[2]) else {
            print("usage: signal-host <media-url> <new-output-directory> <run-id>")
            exit(2)
        }
        guard #available(macOS 27, *) else {
            print("signal-host requires macOS 27")
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task {
            do {
                if ProcessInfo.processInfo.environment["SIGNAL_LAB_OBSERVE_EXISTING"] == "1" {
                    let item = AVPlayerItem(url: url)
                    let player = AVPlayer(playerItem: item)
                    player.play()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(15))
                    while player.currentTime().seconds < 2, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard player.currentTime().seconds >= 2 else { throw NSError(domain: "ObserverStart", code: 1) }
                    try await DebugPlaybackSignalCapture.observe(player: player, runID: CommandLine.arguments[3],
                        directory: URL(fileURLWithPath: CommandLine.arguments[2]))
                    guard player.currentItem === item else { throw NSError(domain: "ObserverReplacedItem", code: 1) }
                    guard player.rate > 0, player.currentTime().seconds >= 9.8 else { throw NSError(domain: "ObserverStoppedPlayback", code: 1) }
                    player.pause()
                } else {
                try await DebugPlaybackSignalCapture.run(url: url, headers: [:],
                    runID: CommandLine.arguments[3], captureAudioTap: ProcessInfo.processInfo.environment["SIGNAL_LAB_AUDIO_TAP"] == "1", tapPostEffects: ProcessInfo.processInfo.environment["SIGNAL_LAB_TAP_PRE_EFFECTS"] != "1", pitchAlgorithm: ProcessInfo.processInfo.environment["SIGNAL_LAB_PITCH_ALGORITHM"], captureDecodedAudio: ProcessInfo.processInfo.environment["SIGNAL_LAB_DISABLE_DECODED_AUDIO"] != "1", requestedChannels: Int(ProcessInfo.processInfo.environment["SIGNAL_LAB_CHANNELS"] ?? "2") ?? 2, directory: URL(fileURLWithPath: CommandLine.arguments[2]))
                }
                exit(0)
            } catch {
                print("capture failed: \(error)")
                exit(1)
            }
        }
        app.run()
    }
}
