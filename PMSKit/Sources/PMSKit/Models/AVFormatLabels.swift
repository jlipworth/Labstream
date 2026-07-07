import Foundation

/// Friendly AV format names for the Stats panel (GH #195): marketing audio names
/// ("Dolby Digital Plus (E-AC-3) 5.1", "DTS-HD MA 7.1") and a combined video
/// codec + HDR line ("HEVC · Dolby Vision P8 (HDR10 fallback)").
///
/// Purely presentational string mapping — no playback policy hangs off these names.
/// Unknown codecs fall through as the raw identifier uppercased so the panel never
/// shows less than the raw fact.
public enum AVFormatLabels {

    /// "5.1", "7.1", "2.0", "Mono" from a raw channel count. A bare count can't distinguish
    /// e.g. 5.0 from 4.1, so use the conventional layout for each count: 4 ch is quad ("4.0")
    /// and 5 ch is "5.0", not the "\(n-1).1" that only holds for 3/6/7/8 channels.
    public static func channelLayoutName(_ channels: Int?) -> String? {
        guard let channels, channels > 0 else { return nil }
        switch channels {
        case 1: return "Mono"
        case 2: return "2.0"
        case 4: return "4.0"
        case 5: return "5.0"
        default: return "\(channels - 1).1"
        }
    }

    /// Marketing-style audio format name with channel layout appended.
    /// `profile` is the backend codec-profile string (Plex `Stream.profile`,
    /// Jellyfin/Emby `Profile`) used to distinguish DTS-HD MA / DTS:X / Atmos.
    public static func audioDisplayName(codec: String?, channels: Int?, profile: String? = nil) -> String? {
        guard let codec = codec?.lowercased(), !codec.isEmpty else { return nil }
        let profileLowered = profile?.lowercased() ?? ""
        let hasAtmos = profileLowered.contains("atmos")

        var name: String
        switch codec {
        case "ac3": name = "Dolby Digital (AC-3)"
        case "eac3", "ec3", "ec-3": name = "Dolby Digital Plus (E-AC-3)"
        case "truehd": name = "Dolby TrueHD"
        case "dca", "dts":
            if profileLowered.contains("dts:x") || profileLowered.contains("dts-x") || profileLowered == "x" {
                name = "DTS:X"
            } else if profileLowered.contains("ma") && !profileLowered.contains("mp3") {
                name = "DTS-HD MA"
            } else if profileLowered.contains("hra") || profileLowered.contains("high resolution") {
                name = "DTS-HD HRA"
            } else {
                name = "DTS"
            }
        case "aac": name = "AAC"
        case "flac": name = "FLAC"
        case "alac": name = "ALAC"
        case "opus": name = "Opus"
        case "vorbis": name = "Vorbis"
        case "mp3": name = "MP3"
        case "mp2": name = "MP2"
        default:
            name = codec.hasPrefix("pcm") ? "PCM" : codec.uppercased()
        }
        if hasAtmos { name += " Atmos" }
        if let layout = channelLayoutName(channels) { name += " \(layout)" }
        return name
    }

    /// Video codec display name plus the HDR classification, joined with " · ".
    public static func videoDisplayName(codec: String?, hdr: VideoHDRMetadata?) -> String? {
        let codecName: String? = switch codec?.lowercased() {
        case nil, "": nil
        case "hevc", "h265": "HEVC"
        case "h264", "avc": "H.264"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "mpeg2video": "MPEG-2"
        case "mpeg4": "MPEG-4"
        case "vc1": "VC-1"
        case let other?: other.uppercased()
        }
        let parts = [codecName, hdr?.displayLabel].compactMap(\.self)
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ")
    }
}
