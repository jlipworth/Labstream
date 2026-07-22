import Foundation

/// Platform-neutral metadata for a video system-media publisher.
///
/// The app intentionally has two native publication mechanisms: iOS/macOS publish through the
/// process-wide Now Playing center, while visionOS attaches metadata to the active `AVPlayerItem`
/// in a scoped `MPNowPlayingSession`. This snapshot keeps their content and formatting identical
/// without coupling PMSKit to MediaPlayer or erasing those different ownership models.
public struct VideoNowPlayingSnapshot: Equatable, Sendable {
    public let title: String
    public let context: String?
    public let releaseYear: Int?
    public let durationMilliseconds: Int?
    public let elapsedMilliseconds: Int
    public let playbackRate: Double
    public let defaultPlaybackRate: Double

    public init(mediaItem: MediaItem,
                durationMilliseconds: Int?,
                elapsedMilliseconds: Int,
                playbackRate: Double,
                defaultPlaybackRate: Double) {
        title = mediaItem.title
        context = Self.context(for: mediaItem)
        releaseYear = mediaItem.year
        self.durationMilliseconds = Self.positive(durationMilliseconds)
            ?? Self.positive(mediaItem.duration)
        self.elapsedMilliseconds = max(0, elapsedMilliseconds)
        self.playbackRate = playbackRate
        self.defaultPlaybackRate = defaultPlaybackRate
    }

    /// Episode context uses the same show + season/episode vocabulary as the rest of the app.
    /// A backend that supplies no numeric episode code may still supply a useful season title.
    /// Movies use the release year as their lightweight context label.
    public static func context(for item: MediaItem) -> String? {
        if item.kind == .episode {
            var parts: [String] = []
            if let show = nonEmpty(item.grandparentTitle) { parts.append(show) }
            if let code = item.seasonEpisodeCode {
                parts.append(code)
            } else if let season = nonEmpty(item.parentTitle) {
                parts.append(season)
            }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
        return item.year.map(String.init)
    }

    private static func positive(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
