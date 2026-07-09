import Foundation

/// The audio track a server-prepared download should ask the backend to bake into the output file.
public struct DownloadAudioTrackSelection: Sendable, Equatable {
    /// Plex uses `Stream.id`; Jellyfin/Emby canonical streams map `MediaStream.Index` into `id`.
    public let streamIndex: Int
    /// Short user-facing label suitable for picker/download sheet captions.
    public let displayName: String

    public init(streamIndex: Int, displayName: String) {
        self.streamIndex = streamIndex
        self.displayName = displayName
    }
}

/// Shared audio-track defaulting for offline-download starts.
///
/// Server-prepared download lanes usually produce one audio stream. When the caller has an active
/// playback override, use it. Otherwise mirror the player's metadata fallback: selected track,
/// container default, then first audio stream.
public enum DownloadAudioSelectionPolicy {
    public static func selectedAudioStreamIndex(part: Part?,
                                                overrideStreamIndex: Int? = nil) -> Int? {
        selectedAudioTrack(part: part, overrideStreamIndex: overrideStreamIndex)?.streamIndex
    }

    public static func selectedAudioTrack(part: Part?,
                                          overrideStreamIndex: Int? = nil) -> DownloadAudioTrackSelection? {
        let streams = part?.audioStreams ?? []
        if let overrideStreamIndex, overrideStreamIndex >= 0 {
            let match = streams.first { stream in
                stream.id == overrideStreamIndex || stream.index == overrideStreamIndex
            }
            return makeSelection(streamIndex: overrideStreamIndex, stream: match, position: nil)
        }

        guard let selected = streams.first(where: { $0.selected == true })
            ?? streams.first(where: { $0.isDefault == true })
            ?? streams.first else {
            return nil
        }
        let position = streams.firstIndex(where: { $0.id == selected.id }).map { $0 + 1 }
        return makeSelection(streamIndex: selected.id, stream: selected, position: position)
    }

    private static func makeSelection(streamIndex: Int,
                                      stream: Stream?,
                                      position: Int?) -> DownloadAudioTrackSelection {
        let displayName = displayName(for: stream, streamIndex: streamIndex, position: position)
        return DownloadAudioTrackSelection(streamIndex: streamIndex, displayName: displayName)
    }

    private static func displayName(for stream: Stream?,
                                    streamIndex: Int,
                                    position: Int?) -> String {
        if let label = firstNonEmpty(stream?.displayTitle, stream?.extendedDisplayTitle) {
            return label
        }

        var pieces: [String] = []
        if let language = firstNonEmpty(stream?.language, stream?.title) {
            pieces.append(language)
        }
        if let format = AVFormatLabels.audioDisplayName(codec: stream?.codec,
                                                        channels: stream?.channels,
                                                        profile: stream?.profile) {
            pieces.append(format)
        }
        if !pieces.isEmpty {
            return pieces.joined(separator: " · ")
        }
        if let position {
            return "Track \(position)"
        }
        return "Track \(streamIndex)"
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}
