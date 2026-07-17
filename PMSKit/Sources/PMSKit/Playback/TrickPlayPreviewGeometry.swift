/// Pure coordinate helpers for pointer-driven trick-play previews.
public enum TrickPlayPreviewGeometry {
    /// Maps a pointer's local horizontal position to a clamped media target.
    public static func targetMs(pointerX: Double, trackWidth: Double, durationMs: Int) -> Int? {
        guard trackWidth > 0, durationMs > 0 else { return nil }
        let fraction = min(max(pointerX / trackWidth, 0), 1)
        return Int((Double(durationMs) * fraction).rounded())
    }

    /// Keeps a preview card centered on the pointer without clipping either track edge.
    public static func cardCenterX(pointerX: Double, trackWidth: Double, cardWidth: Double) -> Double {
        guard trackWidth > 0 else { return 0 }
        let effectiveCardWidth = min(max(cardWidth, 0), trackWidth)
        let halfWidth = effectiveCardWidth / 2
        return min(max(pointerX, halfWidth), trackWidth - halfWidth)
    }
}

/// Pure state policy for resolving asynchronous trick-play thumbnail requests.
///
/// The preview's primary timestamp describes the user's seek target, not the capture time of an
/// approximate thumbnail. Those values are often close for dense Plex/Jellyfin indexes, but may be
/// many minutes apart for a sparse chapter-image provider such as Emby.
public enum TrickPlayPreviewResolutionPolicy {
    public enum Completion: Equatable, Sendable {
        case ignoredStale
        case showImage(captureTimeMs: Int)
        case clearImage
    }

    public static func displayedTimeMs(targetMs: Int?,
                                       thumbnailCaptureTimeMs: Int?,
                                       fallbackMs: Int) -> Int {
        // Keep the capture time in the API so callers cannot accidentally conflate it with the
        // target again. It is useful for image-cache identity, but never for the primary seek label.
        _ = thumbnailCaptureTimeMs
        return max(0, targetMs ?? fallbackMs)
    }

    public static func completion(requestGeneration: Int,
                                  currentGeneration: Int,
                                  requestTargetMs: Int,
                                  activeTargetMs: Int?,
                                  decodedThumbnailTimeMs: Int?) -> Completion {
        guard requestGeneration == currentGeneration,
              activeTargetMs == requestTargetMs else {
            return .ignoredStale
        }
        guard let decodedThumbnailTimeMs else { return .clearImage }
        return .showImage(captureTimeMs: max(0, decodedThumbnailTimeMs))
    }
}
