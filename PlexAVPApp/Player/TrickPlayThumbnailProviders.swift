import Foundation
import PMSKit
import UIKit

/// Plex BIF-backed trick-play provider.
///
/// Fetches at most one BIF index for the selected Part and serves all scrub previews from that
/// in-memory index. This is intentionally independent of `PlaybackController` stream rebuilds so
/// dragging the scrubber cannot create extra transcode/reconnect pressure.
actor PlexBIFTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private let request: PlexRequest
    private let client: PlexClient
    private var loadedIndex: BIFIndex?
    private var loadTask: Task<BIFIndex?, Never>?

    init?(item: MediaItem,
          mediaIndex: Int,
          server: URL,
          token: String,
          identity: ClientIdentity,
          client: PlexClient) {
        guard let part = Self.selectedPart(from: item, mediaIndex: mediaIndex),
              part.hasStandardDefinitionBIFIndex else {
            return nil
        }
        self.request = TrickPlayRequest.plexBIFIndex(server: server,
                                                     token: token,
                                                     identity: identity,
                                                     partID: part.id,
                                                     quality: "sd")
        self.client = client
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        guard let index = await index(), let frame = index.frame(nearMs: targetMs) else { return nil }
        return TrickPlayThumbnail(timeMs: frame.timeMs,
                                  imageData: frame.data,
                                  contentType: "image/jpeg")
    }

    private func index() async -> BIFIndex? {
        if let loadedIndex { return loadedIndex }
        if loadTask == nil {
            let request = request
            let client = client
            loadTask = Task {
                do {
                    let data = try await client.send(request)
                    return try BIFParser.parse(data)
                } catch {
                    // Unavailable BIFs are expected for some items/servers. Keep this silent and
                    // graceful; do not log URLs because the request carries an auth token in query.
                    return nil
                }
            }
        }
        let value = await loadTask?.value
        loadedIndex = value ?? nil
        return value ?? nil
    }

    private static func selectedPart(from item: MediaItem, mediaIndex: Int) -> Part? {
        guard let media = item.media, !media.isEmpty else { return nil }
        let selectedMedia = media.indices.contains(mediaIndex) ? media[mediaIndex] : media[0]
        return selectedMedia.part.first
    }
}

/// Jellyfin-aware seam placeholder.
///
/// Jellyfin can expose trick-play-style images only when the server has generated preview assets
/// for a library item. The exact low-pressure sprite/tile endpoint should be wired here later;
/// for now this provider makes Jellyfin playback explicitly and gracefully unavailable without
/// falling back to chapter images or creating playback-stream requests during scrubbing.
struct JellyfinTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    // TODO(#4 Jellyfin parity): implement against Jellyfin preview thumbnail/sprite endpoints once
    // generated trick-play availability can be detected cheaply per item/media source.
    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? { nil }
}

@MainActor
final class TrickPlayPreviewImageCache {
    private let limit: Int
    private var images: [Int: UIImage] = [:]
    private var order: [Int] = []

    init(limit: Int = 32) {
        self.limit = max(1, limit)
    }

    func image(for timeMs: Int) -> UIImage? {
        images[timeMs]
    }

    func nearestImage(to targetMs: Int, toleranceMs: Int) -> (timeMs: Int, image: UIImage)? {
        guard !images.isEmpty else { return nil }
        let nearest = images.keys.min { lhs, rhs in
            abs(lhs - targetMs) < abs(rhs - targetMs)
        }
        guard let nearest, abs(nearest - targetMs) <= toleranceMs, let image = images[nearest] else {
            return nil
        }
        return (nearest, image)
    }

    func insert(_ image: UIImage, for timeMs: Int) {
        if images[timeMs] == nil {
            order.append(timeMs)
        }
        images[timeMs] = image
        while order.count > limit, let oldest = order.first {
            order.removeFirst()
            images[oldest] = nil
        }
    }

    func clear() {
        images.removeAll()
        order.removeAll()
    }
}
