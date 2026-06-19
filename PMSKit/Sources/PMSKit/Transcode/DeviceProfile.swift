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

    /// Build the visionOS device profile, capping the transcoded video bitrate and, for
    /// low/mid quality ladder rungs, audio bitrate.
    /// - Parameter maxVideoBitrateKbps: hard cap on transcoded video bitrate, in kbps.
    /// - Parameter maxAudioBitrateKbps: optional cap on transcoded audio bitrate, in kbps.
    public static func visionOS(maxVideoBitrateKbps: Int,
                                maxAudioBitrateKbps: Int? = nil) -> DeviceProfile {
        // HEVC over HLS must use the fMP4 (mp4) container; H.264 works in both ts and mp4.
        var directives = [
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=h264,hevc&audioCodec=aac,ac3)",
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=ts&videoCodec=h264&audioCodec=aac,ac3)",
            "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.bitrate&value=\(maxVideoBitrateKbps))",
        ]
        if let maxAudioBitrateKbps {
            directives.append("add-limitation(scope=audioCodec&scopeName=*&type=upperBound&name=audio.bitrate&value=\(maxAudioBitrateKbps))")
        }
        return DeviceProfile(clientProfileExtra: directives.joined(separator: "+"))
    }

    /// Direct-play-capable profile used ONLY by the decision probe (issue #7). Prepends an
    /// `add-direct-play-profile` and marks the bitrate limit `isRequired=true` so above-cap
    /// sources are forced to transcode rather than direct-played over the cap. NOT used by the
    /// production playback request yet.
    ///
    /// Whitelists only the lowest-risk codec/container/audio intersection that AVPlayer
    /// can also open as a local offline file: H.264/HEVC video in MP4-family containers
    /// (`mp4`, `m4v`, `mov`) with AAC or AC-3 audio (research/13 §1.1, §3.1). AV1 /
    /// Dolby Vision / TrueHD / DTS / EAC3 are deliberately omitted so they
    /// fall to the transcode path until verified on-device.
    ///
    /// The two `add-transcode-target` directives are identical to `visionOS(...)` so
    /// above-cap (or non-whitelisted) sources still have a valid transcode target.
    /// - Parameter maxVideoBitrateKbps: hard cap on video bitrate, in kbps; `isRequired=true`.
    /// - Parameter maxAudioBitrateKbps: optional cap on audio bitrate, in kbps.
    public static func visionOSDirectPlayProbe(maxVideoBitrateKbps: Int,
                                               maxAudioBitrateKbps: Int? = nil) -> DeviceProfile {
        var directives = [
            "add-direct-play-profile(type=videoProfile&container=mp4,m4v,mov&videoCodec=h264,hevc&audioCodec=aac,ac3)",
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=h264,hevc&audioCodec=aac,ac3)",
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=ts&videoCodec=h264&audioCodec=aac,ac3)",
            "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.bitrate&value=\(maxVideoBitrateKbps)&isRequired=true)",
        ]
        if let maxAudioBitrateKbps {
            directives.append("add-limitation(scope=audioCodec&scopeName=*&type=upperBound&name=audio.bitrate&value=\(maxAudioBitrateKbps))")
        }
        return DeviceProfile(clientProfileExtra: directives.joined(separator: "+"))
    }
}
