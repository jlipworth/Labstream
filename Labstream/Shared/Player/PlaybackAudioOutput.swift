import Foundation
#if !os(macOS)
import AVFAudio
#endif

/// The system audio route as the Stats panel shows it: channel layout and connection kind.
///
/// This is what the device sends on, not what the stream carries. A television that advertises
/// 5.1 over HDMI makes Apple TV send 5.1 even when stereo speakers sit behind it, which plays
/// with very quiet dialogue; seeing "5.1 · HDMI" here is the clue. The route's device name is
/// never used, because it can be personal ("Sam's AirPods").
enum PlaybackAudioOutput {
    static func label(channels: Int, connection: String?) -> String? {
        guard channels > 0 else { return nil }
        let layout: String = switch channels {
        case 1: "Mono"
        case 2: "Stereo"
        case 6: "5.1"
        case 8: "7.1"
        default: "\(channels) channels"
        }
        guard let connection, !connection.isEmpty else { return layout }
        return "\(layout) \u{00B7} \(connection)"
    }

    /// The current route, or nil where the platform has no audio session (macOS).
    static func current() -> String? {
        #if os(macOS)
        return nil
        #else
        let session = AVAudioSession.sharedInstance()
        let connection: String? = session.currentRoute.outputs.first.flatMap { output in
            switch output.portType {
            case .HDMI: "HDMI"
            case .airPlay: "AirPlay"
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP: "Bluetooth"
            case .headphones: "Headphones"
            case .builtInSpeaker: "Speaker"
            case .usbAudio: "USB"
            default: nil
            }
        }
        return label(channels: session.outputNumberOfChannels, connection: connection)
        #endif
    }
}
