import Foundation
import PMSKit

/// Shared source facts used by both Stats for Nerds and exported diagnostics.
///
/// Keep this app-local: it bridges canonical PMSKit models into the presentation/reporting
/// fields the Labstream player owns without moving UI labels into PMSKit.
struct PlaybackSourceSummary: Equatable {
    var container: String?
    var videoCodec: String?
    var audioCodec: String?
    var bitrateKbps: Int = 0
    var width: Int?
    var height: Int?
    var durationMs: Int?
    var partIndex: Int = 0
    var subtitleMode: String = "none"
    var audioChannels: Int?
    /// Source HDR classification from backend stream metadata (#195). Nil when the
    /// backend exposed no color/DV facts for the video stream.
    var hdr: VideoHDRMetadata?
    /// Audio codec profile string (Plex `profile` / MediaBrowser `Profile`), used to
    /// distinguish DTS-HD MA / DTS:X / Atmos in the Stats audio row (#195).
    var audioProfile: String?

    var statsResolution: String? {
        guard let width, let height else { return nil }
        return "\(width)×\(height)"
    }

    var diagnosticResolution: String? {
        guard let width, let height else { return nil }
        return "\(width)x\(height)"
    }

    var diagnosticFields: [String: DiagnosticFieldValue] {
        var fields: [String: DiagnosticFieldValue] = [
            "source_container": .label(container),
            "source_video_codec": .label(videoCodec),
            "source_audio_codec": .label(audioCodec),
            "source_bitrate_kbps": .int(bitrateKbps),
        ]
        if let durationMs {
            fields["duration"] = .millisecondsBucket(durationMs)
        }
        fields["part_index"] = .int(partIndex)
        fields["subtitle_mode"] = .label(subtitleMode)
        if let diagnosticResolution {
            fields["source_resolution"] = .label(diagnosticResolution)
        }
        if let audioChannels {
            fields["source_audio_channels"] = .int(audioChannels)
        }
        if let hdr {
            fields["source_hdr"] = .label(hdr.format.rawValue)
            fields["source_hdr_detail"] = .label(hdr.displayLabel)
        }
        return fields
    }

    static func plex(item: MediaItem, mediaIndex: Int) -> PlaybackSourceSummary {
        let media = item.media.flatMap { mediaItems -> Media? in
            if mediaItems.indices.contains(mediaIndex) { return mediaItems[mediaIndex] }
            return mediaItems.first
        }
        let part = media?.part.first
        // The ACTIVE audio stream (PMS sends `selected` only on it), not blindly the first —
        // on a multi-track part the first stream can be a track that isn't playing at all.
        let audioStream = part?.audioStreams.first { $0.selected == true }
            ?? part?.audioStreams.first { $0.isDefault == true }
            ?? part?.audioStreams.first
        return PlaybackSourceSummary(
            container: media?.container ?? part?.container,
            videoCodec: media?.videoCodec ?? part?.videoStreams.first?.codec,
            audioCodec: media?.audioCodec ?? audioStream?.codec,
            bitrateKbps: media?.bitrate ?? 0,
            width: media?.width,
            height: media?.height,
            durationMs: media?.duration ?? item.duration,
            partIndex: 0,
            subtitleMode: (part?.subtitleStreams.isEmpty == false) ? "available" : "none",
            audioChannels: audioStream?.channels,
            hdr: part?.videoStreams.first?.hdrMetadata,
            audioProfile: audioStream?.profile
        )
    }

    static func mediaBrowser(_ source: MediaBrowserPlaybackSourceMetadata?) -> PlaybackSourceSummary? {
        guard let source else { return nil }
        return PlaybackSourceSummary(
            container: source.container,
            videoCodec: source.videoCodec,
            audioCodec: source.audioCodec,
            bitrateKbps: source.bitrate ?? 0,
            width: source.width,
            height: source.height,
            durationMs: nil,
            partIndex: 0,
            subtitleMode: "none",
            audioChannels: nil,
            hdr: source.hdr,
            audioProfile: source.audioProfile
        )
    }
}
