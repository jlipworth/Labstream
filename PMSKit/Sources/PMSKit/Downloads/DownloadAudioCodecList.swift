import Foundation

/// Builds the `audioCodec` request list for server-prepared downloads. Shared by the
/// Jellyfin and Emby compatible-remux builders so their copy semantics can't diverge.
enum DownloadAudioCodecList {

    /// Codec list for the "Original quality (compatible)" remux lane.
    ///
    /// Jellyfin/Emby only stream-copy an audio track whose codec appears in the requested
    /// `audioCodec` list (`AllowAudioStreamCopy` alone is not sufficient — the same rule the
    /// video side handles by listing the source video codec). So when the caller intends a
    /// copy, list the source codec first with `aac` kept as the re-encode fallback target.
    static func forRemux(sourceAudioCodec: String?, copyAudio: Bool) -> String {
        guard copyAudio,
              let codec = sourceAudioCodec?.lowercased(),
              !codec.isEmpty,
              codec != "aac" else {
            return "aac"
        }
        return "\(codec),aac"
    }
}
