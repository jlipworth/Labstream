import Foundation

/// Shared display labels for online media versions.
///
/// These are intentionally presentation-tier labels, not exact pixel dumps: a scope/wide-aspect
/// encode can preserve the tier width (for example 1280 wide) while its height is below the named
/// rung. Keep this aligned with download/existing-version labels so the same media source is not
/// described differently in DetailView and download UI.
public enum MediaVersionLabel {
    /// Human resolution tier from a `Media` entry's pixel dimensions (4K / 1080p / 720p / …).
    public static func resolutionLabel(for media: Media) -> String? {
        DownloadResolutionLabel.label(width: media.width, height: media.height)
    }

    /// Compact label for a selectable media version, e.g. `4K · HEVC · 24.0 Mbps`.
    public static func versionLabel(for media: Media) -> String {
        var parts: [String] = []
        if let resolution = resolutionLabel(for: media) { parts.append(resolution) }
        if let codec = media.videoCodec?.uppercased(), !codec.isEmpty { parts.append(codec) }
        if let bitrate = media.bitrate, bitrate > 0 {
            parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000))
        }
        return parts.isEmpty ? "Version" : parts.joined(separator: " · ")
    }

    /// Tech-spec badges (resolution · video codec · audio codec · bitrate · container).
    public static func specBadges(for media: Media) -> [String] {
        var specs: [String] = []
        if let resolution = resolutionLabel(for: media) { specs.append(resolution) }
        if let codec = media.videoCodec?.uppercased(), !codec.isEmpty { specs.append(codec) }
        // HDR/DV badge (#195): "DV P8" / "HDR10" / "HDR10+" / "HLG". SDR is the
        // unlabeled default, so only non-SDR classifications earn a chip.
        if let hdr = media.part.first?.videoStreams.first?.hdrMetadata, hdr.format != .sdr {
            specs.append(hdr.shortLabel)
        }
        if let audio = media.audioCodec?.uppercased(), !audio.isEmpty { specs.append(audio) }
        if let bitrate = media.bitrate, bitrate > 0 {
            specs.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000))
        }
        if let container = media.container?.uppercased(), !container.isEmpty { specs.append(container) }
        return specs
    }
}
