import Foundation

/// The client transcode profile we advertise to PMS via `X-Plex-Client-Profile-Extra`.
///
/// The directive grammar (ported from research/09's worked example) is a `+`-separated
/// list of directives, each of the form `name(key=value&key=value&...)`. We declare:
///   - `add-transcode-target` for HLS so PMS knows we want segmented HLS output,
///     listing the containers / video codecs / audio codecs we can play.
///   - `add-limitation` capping the video bitrate so PMS transcodes down to our cap.
///
/// visionOS / AVPlayer plays HLS with fMP4 or MPEG-TS segments and H.264 / HEVC video
/// (HEVC over HLS requires the fMP4 container — see research/09 — which is why `mp4` is
/// listed as a transcode-target container alongside `ts`).
public struct DeviceProfile: Sendable, Equatable {
    /// The fully-rendered value for the `X-Plex-Client-Profile-Extra` param.
    public let clientProfileExtra: String

    public init(clientProfileExtra: String) {
        self.clientProfileExtra = clientProfileExtra
    }

    /// Build the visionOS device profile, capping the transcoded video bitrate.
    /// - Parameter maxVideoBitrateKbps: hard cap on transcoded video bitrate, in kbps.
    public static func visionOS(maxVideoBitrateKbps: Int) -> DeviceProfile {
        // HEVC over HLS must use the fMP4 (mp4) container; H.264 works in both ts and mp4.
        let directives = [
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=h264,hevc&audioCodec=aac,ac3)",
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=ts&videoCodec=h264&audioCodec=aac,ac3)",
            "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.bitrate&value=\(maxVideoBitrateKbps))",
        ]
        return DeviceProfile(clientProfileExtra: directives.joined(separator: "+"))
    }
}
