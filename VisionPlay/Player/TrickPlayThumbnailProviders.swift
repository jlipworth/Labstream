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

/// Jellyfin image-tile trick-play provider.
///
/// Jellyfin exposes generated trickplay as an image-only HLS playlist plus 10x10 JPEG tile sheets.
/// This provider loads the playlist once, fetches only the sheet needed for the current scrub
/// target, crops the relevant tile, and returns that JPEG without touching playback streams.
actor JellyfinTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private let itemId: String
    private let mediaSourceId: String
    private let server: URL
    private let token: String
    private let identity: JellyfinClientIdentity
    private let width: Int
    private let session: URLSession

    private var loadedPlaylist: JellyfinTrickPlayPlaylist?
    private var playlistTask: Task<JellyfinTrickPlayPlaylist?, Never>?
    private var tileImages: [String: UIImage] = [:]
    private var tileOrder: [String] = []
    private let tileCacheLimit = 4

    init?(item: MediaItem,
          server: URL?,
          token: String?,
          identity: JellyfinClientIdentity,
          width: Int = 320,
          session: URLSession = .shared) {
        guard let server, let token, !token.isEmpty else { return nil }
        self.itemId = item.ratingKey
        self.mediaSourceId = Self.mediaSourceId(from: item) ?? item.ratingKey
        self.server = server
        self.token = token
        self.identity = identity
        self.width = width
        self.session = session
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        guard let playlist = await playlist(), let frame = playlist.frame(nearMs: targetMs) else { return nil }
        guard let sheet = await tileImage(for: frame.tile) else { return nil }
        guard let cropped = crop(sheet: sheet, frame: frame),
              let data = cropped.jpegData(compressionQuality: 0.82) else { return nil }
        return TrickPlayThumbnail(timeMs: frame.timeMs, imageData: data, contentType: "image/jpeg")
    }

    private func playlist() async -> JellyfinTrickPlayPlaylist? {
        if let loadedPlaylist { return loadedPlaylist }
        if playlistTask == nil {
            let server = server, token = token, identity = identity, itemId = itemId, mediaSourceId = mediaSourceId, width = width, session = session
            playlistTask = Task {
                do {
                    let req = try JellyfinLibrary.trickPlayPlaylistRequest(server: server,
                                                                           token: token,
                                                                           identity: identity,
                                                                           itemId: itemId,
                                                                           mediaSourceId: mediaSourceId,
                                                                           width: width)
                    let (data, response) = try await session.data(for: req)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                          let text = String(data: data, encoding: .utf8) else { return nil }
                    return try JellyfinTrickPlayPlaylistParser.parse(text)
                } catch {
                    return nil
                }
            }
        }
        let value = await playlistTask?.value
        loadedPlaylist = value ?? nil
        return value ?? nil
    }

    private func tileImage(for tile: JellyfinTrickPlayTile) async -> UIImage? {
        if let cached = tileImages[tile.uri] { return cached }
        do {
            let req = try JellyfinLibrary.trickPlayTileRequest(server: server,
                                                               token: token,
                                                               identity: identity,
                                                               itemId: itemId,
                                                               mediaSourceId: mediaSourceId,
                                                               width: width,
                                                               tileURI: tile.uri)
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let image = UIImage(data: data) else { return nil }
            insertTile(image, for: tile.uri)
            return image
        } catch {
            return nil
        }
    }

    private func insertTile(_ image: UIImage, for uri: String) {
        if tileImages[uri] == nil { tileOrder.append(uri) }
        tileImages[uri] = image
        while tileOrder.count > tileCacheLimit, let oldest = tileOrder.first {
            tileOrder.removeFirst()
            tileImages[oldest] = nil
        }
    }

    private nonisolated func crop(sheet: UIImage, frame: JellyfinTrickPlayFrame) -> UIImage? {
        guard let cgImage = sheet.cgImage else { return nil }
        let scaleX = CGFloat(cgImage.width) / CGFloat(frame.tile.columns * frame.tile.tileWidth)
        let scaleY = CGFloat(cgImage.height) / CGFloat(frame.tile.rows * frame.tile.tileHeight)
        let rect = CGRect(x: CGFloat(frame.column * frame.tile.tileWidth) * scaleX,
                          y: CGFloat(frame.row * frame.tile.tileHeight) * scaleY,
                          width: CGFloat(frame.tile.tileWidth) * scaleX,
                          height: CGFloat(frame.tile.tileHeight) * scaleY).integral
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped, scale: sheet.scale, orientation: sheet.imageOrientation)
    }

    private static func mediaSourceId(from item: MediaItem) -> String? {
        guard let key = item.media?.first?.part.first?.key,
              let url = URL(string: key),
              url.scheme == "jellyfin",
              url.host == "item" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "media" else { return nil }
        return parts[2]
    }
}

/// Emby chapter-image trick-play provider.
///
/// Emby exposes no Jellyfin-style trickplay tile sheets (`/Trickplay/.../tiles.m3u8` 404s), so
/// there is no fine-grained sprite source. Emby DOES expose a per-chapter image endpoint, which
/// is exactly the data the chapter list already uses. This provider reuses the item's chapter
/// markers (each carries a synthetic `emby://item/{id}/Chapter/{index}?tag=` thumb key plus a
/// `startTimeOffset`) to serve a coarse, chapter-granularity scrub preview: it maps the scrub
/// target to the chapter it falls within and fetches that chapter's image once, caching it.
///
/// This is intentionally coarse (one frame per chapter, not per-second) — matching the project's
/// design constraint of never pressuring the transcoder for previews. Like the other providers it
/// is playback-passive: it only fetches images and never touches the media session.
actor EmbyChapterTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private struct Frame: Sendable {
        let timeMs: Int
        let itemId: String
        let index: Int
        let tag: String?
    }

    private let frames: [Frame]
    private let server: URL
    private let token: String
    private let identity: EmbyClientIdentity
    private let userId: String?
    private let session: URLSession

    private var imageCache: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private let cacheLimit = 12

    init?(item: MediaItem,
          server: URL?,
          token: String?,
          identity: EmbyClientIdentity,
          userId: String?,
          session: URLSession = .shared) {
        guard let server, let token, !token.isEmpty else { return nil }
        let frames = (item.chapters ?? []).compactMap { chapter -> Frame? in
            guard let thumb = chapter.thumb, let parsed = Self.parse(thumb) else { return nil }
            return Frame(timeMs: max(0, chapter.startTimeOffset ?? 0),
                         itemId: parsed.itemId,
                         index: parsed.index,
                         tag: parsed.tag)
        }.sorted { $0.timeMs < $1.timeMs }
        // No chapters carry images (e.g. container-derived chapters without thumbnails) → nothing
        // to preview; let the player fall back to the timecode-only scrubber.
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.server = server
        self.token = token
        self.identity = identity
        self.userId = userId
        self.session = session
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        guard let frame = nearestFrame(to: targetMs) else { return nil }
        if let data = imageCache[frame.index] {
            return TrickPlayThumbnail(timeMs: frame.timeMs, imageData: data, contentType: "image/jpeg")
        }
        do {
            let url = try EmbyLibrary.chapterImageURL(server: server,
                                                      itemId: frame.itemId,
                                                      chapterIndex: frame.index,
                                                      tag: frame.tag,
                                                      width: 480,
                                                      height: 270)
            var req = EmbyLibrary.authenticatedRequest(url: url, token: token, identity: identity, userId: userId)
            req.httpMethod = "GET"
            // Image endpoint, not JSON — override the helper's `Accept: application/json`.
            req.setValue("*/*", forHTTPHeaderField: "Accept")
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), !data.isEmpty else {
                return nil
            }
            insert(data, for: frame.index)
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg"
            return TrickPlayThumbnail(timeMs: frame.timeMs, imageData: data, contentType: contentType)
        } catch {
            // Unavailable chapter images are expected; keep silent and graceful and never log the
            // URL (it carries the auth token on the live request).
            return nil
        }
    }

    /// The chapter the scrub target falls within: the last chapter whose start is at or before the
    /// target, falling back to the first chapter for targets before the first marker.
    private func nearestFrame(to targetMs: Int) -> Frame? {
        guard !frames.isEmpty else { return nil }
        let clamped = max(0, targetMs)
        return frames.last { $0.timeMs <= clamped } ?? frames.first
    }

    private func insert(_ data: Data, for index: Int) {
        if imageCache[index] == nil { cacheOrder.append(index) }
        imageCache[index] = data
        while cacheOrder.count > cacheLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            imageCache[oldest] = nil
        }
    }

    /// Parses the synthetic `emby://item/{itemId}/Chapter/{index}?tag=` chapter-image key produced
    /// by `EmbyChapterDto.toPlexChapter`. Mirrors `PlaybackController.parsedEmbyChapterImagePath`.
    private static func parse(_ imagePath: String) -> (itemId: String, index: Int, tag: String?)? {
        guard let url = URL(string: imagePath),
              url.scheme == "emby",
              url.host == "item" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[1] == "Chapter", let index = Int(parts[2]) else { return nil }
        let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == "tag" }?
            .value
        return (parts[0], index, tag)
    }
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
