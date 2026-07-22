import Foundation
import PMSKit

enum TrickPlayCacheBudget {
    /// Two ordinary 3200x1800 RGBA Jellyfin sheets fit; unusually large sheets are used once but
    /// never retained. The entry ceiling also protects servers that advertise many tiny sheets.
    static let decodedTileSheets = 64 * 1_024 * 1_024
    static let decodedTileSheetEntries = 4
    static let encodedGeneratedFrames = 8 * 1_024 * 1_024
    static let encodedGeneratedFrameEntries = 12
    static let decodedPreviewFrames = 16 * 1_024 * 1_024
    static let decodedPreviewFrameEntries = 32
}

private func decodedImageByteCost(_ image: DecodedImage) -> Int {
    let (cost, overflow) = image.cgImage.bytesPerRow.multipliedReportingOverflow(
        by: image.cgImage.height
    )
    return overflow ? Int.max : max(1, cost)
}

/// Shared one-load BIF frame source used by Plex, Emby, and local offline providers. Parsing,
/// malformed-asset fallback, nearest-frame lookup, and cancellation retry behavior live here so
/// backend wrappers cannot drift or introduce a second Roku BIF implementation.
actor BIFBackedTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    typealias DataLoader = @Sendable () async throws -> Data
    typealias IndexLoader = @Sendable () async throws -> BIFIndex

    private let indexLoader: IndexLoader
    private var loadedIndex: BIFIndex?
    private var resolved = false
    private var loadTask: Task<BIFIndex?, Never>?

    init(dataLoader: @escaping DataLoader) {
        self.indexLoader = {
            try BIFParser.parse(try await dataLoader())
        }
    }

    init(mappedFileURL: URL) {
        self.indexLoader = {
            try BIFParser.parse(contentsOf: mappedFileURL)
        }
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        guard let index = await index(), let frame = index.frame(nearMs: targetMs) else { return nil }
        return TrickPlayThumbnail(timeMs: frame.timeMs,
                                  imageData: frame.data,
                                  contentType: "image/jpeg")
    }

    private func index() async -> BIFIndex? {
        if resolved { return loadedIndex }
        // Single-flight: the scrubber cancels and re-fires a `thumbnail(nearMs:)` per drag target,
        // and the actor is reentrant at the `await` below, so without one shared load each concurrent
        // caller would fire its own full (~6 MB) BIF fetch. The load runs in an unstructured `Task` so
        // that one caller's cancellation cannot cancel the fetch every other in-flight caller awaits.
        let task: Task<BIFIndex?, Never>
        if let loadTask {
            task = loadTask
        } else {
            let indexLoader = indexLoader
            task = Task {
                do {
                    return try await indexLoader()
                } catch {
                    // Unavailable/malformed BIFs are expected for some items/servers; cache the miss
                    // silently and never log the URL (the request carries an auth token in its query).
                    return nil
                }
            }
            loadTask = task
        }
        // The shared load always runs to completion (it is not tied to any caller's cancellation), so a
        // genuine parse/load failure caches nil here — a resolved miss, not a retry.
        let parsed = await task.value
        loadedIndex = parsed
        resolved = true
        return parsed
    }
}

/// Plex wrapper that resolves the selected Part request and delegates BIF behavior to the shared
/// frame source. It remains independent of playback session rebuilds.
actor PlexBIFTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private let provider: BIFBackedTrickPlayThumbnailProvider

    init?(item: MediaItem,
          mediaIndex: Int,
          server: URL,
          token: String,
          identity: ClientIdentity,
          session: URLSession = SideAssetTransportPolicy.sharedSession,
          coordinator: SideAssetFetchCoordinator = .shared) {
        guard let part = Self.selectedPart(from: item, mediaIndex: mediaIndex),
              part.hasStandardDefinitionBIFIndex else {
            return nil
        }
        let request = TrickPlayRequest.plexBIFIndex(server: server,
                                                    token: token,
                                                    identity: identity,
                                                    partID: part.id,
                                                    quality: "sd")
        self.provider = BIFBackedTrickPlayThumbnailProvider {
            try await coordinator.fetch(
                request: request.urlRequest(),
                owner: SideAssetOwner(rawValue: "player-trickplay"),
                session: session)
        }
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        await provider.thumbnail(nearMs: targetMs)
    }

    private static func selectedPart(from item: MediaItem, mediaIndex: Int) -> Part? {
        guard let media = item.media, !media.isEmpty else { return nil }
        let selectedMedia = media.indices.contains(mediaIndex) ? media[mediaIndex] : media[0]
        return selectedMedia.part.first
    }
}


/// Local BIF-backed trick-play provider for offline Plex downloads.
///
/// Loads the cached `.bif` once from disk and then serves scrub previews without any
/// server/client dependency. Missing or corrupt cache files simply produce no previews.
actor LocalBIFTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private let provider: BIFBackedTrickPlayThumbnailProvider

    init?(bifURL: URL?) {
        guard let bifURL else { return nil }
        self.provider = BIFBackedTrickPlayThumbnailProvider(mappedFileURL: bifURL)
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        await provider.thumbnail(nearMs: targetMs)
    }
}

/// Crop one frame's tile out of its sheet. Pure; shared by the online and offline Jellyfin
/// trickplay providers (which otherwise duplicated this byte-for-byte) so the timing/crop math lives
/// in one place.
enum JellyfinTrickPlayTileRenderer {
    static func crop(sheet: DecodedImage, frame: JellyfinTrickPlayFrame) -> DecodedImage? {
        let cgImage = sheet.cgImage
        let scaleX = CGFloat(cgImage.width) / CGFloat(frame.tile.columns * frame.tile.tileWidth)
        let scaleY = CGFloat(cgImage.height) / CGFloat(frame.tile.rows * frame.tile.tileHeight)
        let rect = CGRect(x: CGFloat(frame.column * frame.tile.tileWidth) * scaleX,
                          y: CGFloat(frame.row * frame.tile.tileHeight) * scaleY,
                          width: CGFloat(frame.tile.tileWidth) * scaleX,
                          height: CGFloat(frame.tile.tileHeight) * scaleY).integral
        guard let cropped = cgImage.cropping(to: rect) else { return nil }
        return DecodedImage(cgImage: cropped, scale: sheet.scale, orientation: sheet.orientation)
    }
}

/// Small LRU of decoded tile sheets keyed by URI, owned by each Jellyfin trickplay provider so the
/// eviction logic is defined once rather than copied per provider.
struct JellyfinTrickPlayTileCache {
    private var images: CostBoundedLRU<String, DecodedImage>

    init(byteLimit: Int = TrickPlayCacheBudget.decodedTileSheets,
         entryLimit: Int = TrickPlayCacheBudget.decodedTileSheetEntries) {
        images = CostBoundedLRU(costLimit: byteLimit, countLimit: entryLimit)
    }

    /// Promotes the accessed sheet to most-recently-used so an actively-revisited sheet (a scrub that
    /// lingers on one range) isn't the next thing evicted and re-decoded from disk/network.
    mutating func image(for uri: String) -> DecodedImage? {
        images.value(for: uri)
    }

    mutating func insert(_ image: DecodedImage, for uri: String) {
        images.insert(image, for: uri, cost: decodedImageByteCost(image))
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
    private var tileCache = JellyfinTrickPlayTileCache()

    init?(item: MediaItem,
          server: URL?,
          token: String?,
          identity: JellyfinClientIdentity,
          width: Int = 320,
          session: URLSession = SideAssetTransportPolicy.sharedSession) {
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
        guard let cropped = JellyfinTrickPlayTileRenderer.crop(sheet: sheet, frame: frame),
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
                    let data = try await SideAssetFetchCoordinator.shared.fetch(
                        request: req,
                        owner: SideAssetOwner(rawValue: "player-trickplay"),
                        session: session
                    )
                    guard let text = String(data: data, encoding: .utf8) else { return nil }
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

    private func tileImage(for tile: JellyfinTrickPlayTile) async -> DecodedImage? {
        if let cached = tileCache.image(for: tile.uri) { return cached }
        do {
            let req = try JellyfinLibrary.trickPlayTileRequest(server: server,
                                                               token: token,
                                                               identity: identity,
                                                               itemId: itemId,
                                                               mediaSourceId: mediaSourceId,
                                                               width: width,
                                                               tileURI: tile.uri)
            let data = try await SideAssetFetchCoordinator.shared.fetch(
                request: req,
                owner: SideAssetOwner(rawValue: "player-trickplay"),
                session: session
            )
            guard let image = await DecodedImage.decodeEagerlyOffMain(data: data) else { return nil }
            guard !Task.isCancelled else { return nil }
            tileCache.insert(image, for: tile.uri)
            return image
        } catch {
            return nil
        }
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


/// Local Jellyfin tile-sheet provider for offline downloads.
///
/// The cached playlist is a sanitized copy of Jellyfin's trickplay m3u8 whose tile lines are
/// local JPEG filenames, never server URLs or ApiKey query strings. The provider crops the
/// requested tile from those local sheets using the same timing math as the online provider, so
/// preview times align with the downloaded media timeline.
actor LocalJellyfinTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private let playlistURL: URL
    private var loadedPlaylist: JellyfinTrickPlayPlaylist?
    private var playlistTask: Task<JellyfinTrickPlayPlaylist?, Never>?
    private var tileCache = JellyfinTrickPlayTileCache()

    init?(playlistURL: URL?) {
        guard let playlistURL else { return nil }
        self.playlistURL = playlistURL
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        guard let playlist = await playlist(), let frame = playlist.frame(nearMs: targetMs) else { return nil }
        guard let sheet = await tileImage(for: frame.tile) else { return nil }
        guard let cropped = JellyfinTrickPlayTileRenderer.crop(sheet: sheet, frame: frame),
              let data = cropped.jpegData(compressionQuality: 0.82) else { return nil }
        return TrickPlayThumbnail(timeMs: frame.timeMs, imageData: data, contentType: "image/jpeg")
    }

    private func playlist() async -> JellyfinTrickPlayPlaylist? {
        if let loadedPlaylist { return loadedPlaylist }
        if playlistTask == nil {
            let playlistURL = playlistURL
            playlistTask = Task {
                do {
                    let text = try String(contentsOf: playlistURL, encoding: .utf8)
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

    private func tileImage(for tile: JellyfinTrickPlayTile) async -> DecodedImage? {
        if let cached = tileCache.image(for: tile.uri) { return cached }
        let url = playlistURL.deletingLastPathComponent().appendingPathComponent(tile.uri)
        guard let data = try? Data(contentsOf: url),
              let image = await DecodedImage.decodeEagerlyOffMain(data: data),
              !Task.isCancelled else { return nil }
        tileCache.insert(image, for: tile.uri)
        return image
    }
}

/// Emby generated-preview hierarchy for online playback.
///
/// Availability is read from the selected PlaybackInfo source's `ThumbnailSet`. When present, one
/// authenticated parseable BIF is preferred. An unavailable/malformed BIF falls back to bounded
/// per-position images from the same selected source, and any generated-preview failure falls back
/// silently to the existing chapter-image provider. Every request passes through the shared
/// side-asset coordinator and remains independent of playback/transcode sessions.
actor EmbyTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private let itemId: String
    private let mediaSourceId: String
    private let server: URL
    private let token: String
    private let identity: EmbyClientIdentity
    private let userId: String?
    private let width: Int
    private let session: URLSession
    private let coordinator: SideAssetFetchCoordinator
    private let chapterFallback: (any TrickPlayThumbnailProviding)?
    private let bifProvider: BIFBackedTrickPlayThumbnailProvider

    private var thumbnailSet: EmbyThumbnailSetInfo?
    private var thumbnailSetResolved = false
    private var imageCache = CostBoundedLRU<Int64, Data>(
        costLimit: TrickPlayCacheBudget.encodedGeneratedFrames,
        countLimit: TrickPlayCacheBudget.encodedGeneratedFrameEntries
    )

    init?(item: MediaItem,
          mediaSourceId: String,
          server: URL?,
          token: String?,
          identity: EmbyClientIdentity,
          userId: String?,
          width: Int = EmbyTrickPlayRequest.canonicalWidth,
          session: URLSession = SideAssetTransportPolicy.sharedSession,
          coordinator: SideAssetFetchCoordinator = .shared) {
        guard let server, let token, !token.isEmpty, !mediaSourceId.isEmpty else { return nil }
        guard let bifRequest = try? EmbyTrickPlayRequest.bifIndex(
            server: server, token: token, identity: identity, userId: userId,
            itemId: item.ratingKey, mediaSourceId: mediaSourceId, width: width) else { return nil }
        self.itemId = item.ratingKey
        self.mediaSourceId = mediaSourceId
        self.server = server
        self.token = token
        self.identity = identity
        self.userId = userId
        self.width = width
        self.session = session
        self.coordinator = coordinator
        self.bifProvider = BIFBackedTrickPlayThumbnailProvider {
            try await coordinator.fetch(
                request: bifRequest,
                owner: SideAssetOwner(rawValue: "player-trickplay"),
                session: session)
        }
        self.chapterFallback = EmbyChapterTrickPlayThumbnailProvider(
            item: item, server: server, token: token, identity: identity,
            userId: userId, session: session, coordinator: coordinator)
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        guard !Task.isCancelled else { return nil }
        guard let set = await resolvedThumbnailSet(), !set.thumbnails.isEmpty else {
            return await chapterFallback?.thumbnail(nearMs: targetMs)
        }
        if let frame = await bifProvider.thumbnail(nearMs: targetMs) {
            return frame
        }
        if let advertised = set.thumbnail(nearMs: targetMs),
           let data = await perPositionImage(advertised) {
            return TrickPlayThumbnail(timeMs: advertised.timeMs,
                                      imageData: data,
                                      contentType: "image/jpeg")
        }
        return await chapterFallback?.thumbnail(nearMs: targetMs)
    }

    private func resolvedThumbnailSet() async -> EmbyThumbnailSetInfo? {
        if thumbnailSetResolved { return thumbnailSet }
        do {
            let request = try EmbyTrickPlayRequest.thumbnailSet(
                server: server, token: token, identity: identity, userId: userId,
                itemId: itemId, mediaSourceId: mediaSourceId, width: width)
            let data = try await coordinator.fetch(
                request: request,
                owner: SideAssetOwner(rawValue: "player-trickplay"),
                session: session)
            guard !Task.isCancelled else { return nil }
            let decoded = try EmbyThumbnailSetInfo.decode(from: data)
            thumbnailSet = decoded
            thumbnailSetResolved = true
            return decoded
        } catch is CancellationError {
            return nil
        } catch {
            thumbnailSetResolved = true
            return nil
        }
    }

    private func perPositionImage(_ advertised: EmbyThumbnailInfo) async -> Data? {
        if let cached = imageCache.value(for: advertised.positionTicks) {
            return cached
        }
        do {
            let request = try EmbyTrickPlayRequest.thumbnailImage(
                server: server, token: token, identity: identity, userId: userId,
                itemId: itemId, mediaSourceId: mediaSourceId,
                thumbnail: advertised, width: width)
            let data = try await coordinator.fetch(
                request: request,
                owner: SideAssetOwner(rawValue: "player-trickplay"),
                session: session)
            guard !Task.isCancelled, DecodedImage(data: data) != nil else { return nil }
            insertImage(data, for: advertised.positionTicks)
            return data
        } catch {
            return nil
        }
    }

    private func insertImage(_ data: Data, for positionTicks: Int64) {
        imageCache.insert(data, for: positionTicks, cost: data.count)
    }
}

/// Coarse Emby chapter-image fallback used only after generated previews are unavailable.
///
/// The item's chapter markers carry a synthetic `emby://item/{id}/Chapter/{index}?tag=` ref and a
/// `startTimeOffset`; this provider maps the target to that sparse frame and caches bounded JPEGs.
///
/// It remains playback-passive and never touches the media session.
actor EmbyChapterTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private struct Frame: Sendable {
        let timeMs: Int
        let syntheticRef: String
        let index: Int
    }

    private let frames: [Frame]
    private let server: URL
    private let token: String
    private let identity: EmbyClientIdentity
    private let userId: String?
    private let session: URLSession
    private let coordinator: SideAssetFetchCoordinator

    private var imageCache = CostBoundedLRU<Int, Data>(
        costLimit: TrickPlayCacheBudget.encodedGeneratedFrames,
        countLimit: TrickPlayCacheBudget.encodedGeneratedFrameEntries
    )

    init?(item: MediaItem,
          server: URL?,
          token: String?,
          identity: EmbyClientIdentity,
          userId: String?,
          session: URLSession = SideAssetTransportPolicy.sharedSession,
          coordinator: SideAssetFetchCoordinator = .shared) {
        guard let server, let token, !token.isEmpty else { return nil }
        let frames = (item.chapters ?? []).compactMap { chapter -> Frame? in
            guard let thumb = chapter.thumb,
                  let parsed = MediaBrowserSyntheticChapterImageRef.parse(thumb, scheme: EmbyFlavor.syntheticScheme) else { return nil }
            return Frame(timeMs: max(0, chapter.startTimeOffset ?? 0),
                         syntheticRef: thumb,
                         index: parsed.index)
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
        self.coordinator = coordinator
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        guard let frame = nearestFrame(to: targetMs) else { return nil }
        if let data = imageCache.value(for: frame.index) {
            return TrickPlayThumbnail(timeMs: frame.timeMs, imageData: data, contentType: "image/jpeg")
        }
        do {
            guard let req = try EmbyLibrary.chapterImageRequest(syntheticRef: frame.syntheticRef,
                                                                server: server,
                                                                token: token,
                                                                identity: identity,
                                                                userId: userId,
                                                                width: 480,
                                                                height: 270) else { return nil }
            let data = try await coordinator.fetch(
                request: req,
                owner: SideAssetOwner(rawValue: "player-trickplay"),
                session: session
            )
            guard !Task.isCancelled, DecodedImage(data: data) != nil else { return nil }
            insert(data, for: frame.index)
            return TrickPlayThumbnail(timeMs: frame.timeMs, imageData: data, contentType: "image/jpeg")
        } catch {
            // Unavailable chapter images are expected; keep silent and graceful and never log the
            // URL (it carries the auth token on the live request).
            return nil
        }
    }

    /// The chapter the scrub target falls within: the last chapter whose start is at or before the
    /// target, falling back to the first chapter for targets before the first marker.
    private func nearestFrame(to targetMs: Int) -> Frame? {
        guard let index = SparseTrickPlayFrameSelectionPolicy.frameIndex(
            nearMs: targetMs,
            sortedFrameTimesMs: frames.map(\.timeMs)
        ) else { return nil }
        return frames[index]
    }

    private func insert(_ data: Data, for index: Int) {
        imageCache.insert(data, for: index, cost: data.count)
    }

}

/// Local Emby chapter-image trick-play provider for offline downloads (#89).
///
/// Cached chapter images remain the offline fallback when a cached Emby BIF is absent or invalid.
/// This mirrors the online coarse provider but loads JPEGs from disk with no network dependency.
actor LocalEmbyChapterTrickPlayThumbnailProvider: TrickPlayThumbnailProviding {
    private struct Frame: Sendable {
        let timeMs: Int
        let chapterIndex: Int
    }

    private let frames: [Frame]
    private let imageURLsByChapterIndex: [Int: URL]
    private var imageCache = CostBoundedLRU<Int, Data>(
        costLimit: TrickPlayCacheBudget.encodedGeneratedFrames,
        countLimit: TrickPlayCacheBudget.encodedGeneratedFrameEntries
    )

    /// - Parameters:
    ///   - chapters: the offline chapter markers (each carries a `startTimeOffset`), in the same
    ///     order the download-time cache enumerated them.
    ///   - imageURLsByChapterIndex: cached chapter image files keyed by chapter index.
    /// Returns nil when no chapter has both a start time and a cached image — there is nothing to
    /// preview, so the player falls back to the timecode-only scrubber.
    init?(chapters: [OfflineChapter], imageURLsByChapterIndex: [Int: URL]) {
        guard !imageURLsByChapterIndex.isEmpty else { return nil }
        let frames = chapters.enumerated().compactMap { index, chapter -> Frame? in
            guard imageURLsByChapterIndex[index] != nil else { return nil }
            return Frame(timeMs: max(0, chapter.startTimeOffset ?? 0), chapterIndex: index)
        }.sorted { $0.timeMs < $1.timeMs }
        guard !frames.isEmpty else { return nil }
        self.frames = frames
        self.imageURLsByChapterIndex = imageURLsByChapterIndex
    }

    func thumbnail(nearMs targetMs: Int) async -> TrickPlayThumbnail? {
        guard let frame = nearestFrame(to: targetMs) else { return nil }
        if let data = imageCache.value(for: frame.chapterIndex) {
            return TrickPlayThumbnail(timeMs: frame.timeMs, imageData: data, contentType: "image/jpeg")
        }
        guard let url = imageURLsByChapterIndex[frame.chapterIndex],
              let data = try? Data(contentsOf: url),
              DecodedImage(data: data) != nil else { return nil }
        insert(data, for: frame.chapterIndex)
        return TrickPlayThumbnail(timeMs: frame.timeMs, imageData: data, contentType: "image/jpeg")
    }

    /// The chapter the scrub target falls within: the last chapter whose start is at or before the
    /// target, falling back to the first for targets before the first marker. Matches the online provider.
    private func nearestFrame(to targetMs: Int) -> Frame? {
        guard let index = SparseTrickPlayFrameSelectionPolicy.frameIndex(
            nearMs: targetMs,
            sortedFrameTimesMs: frames.map(\.timeMs)
        ) else { return nil }
        return frames[index]
    }

    private func insert(_ data: Data, for index: Int) {
        imageCache.insert(data, for: index, cost: data.count)
    }
}

@MainActor
final class TrickPlayPreviewImageCache {
    private var images: CostBoundedLRU<Int, DecodedImage>

    init(byteLimit: Int = TrickPlayCacheBudget.decodedPreviewFrames,
         entryLimit: Int = TrickPlayCacheBudget.decodedPreviewFrameEntries) {
        images = CostBoundedLRU(costLimit: byteLimit,
                                         countLimit: entryLimit)
    }

    /// Compatibility spelling for existing player construction; byte-cost eviction remains active.
    convenience init(limit: Int) {
        self.init(byteLimit: TrickPlayCacheBudget.decodedPreviewFrames,
                  entryLimit: max(1, limit))
    }

    func image(for timeMs: Int) -> DecodedImage? {
        images.value(for: timeMs)
    }

    func nearestImage(to targetMs: Int, toleranceMs: Int) -> (timeMs: Int, image: DecodedImage)? {
        let keys = images.keys
        guard !keys.isEmpty else { return nil }
        let nearest = keys.min { lhs, rhs in
            abs(lhs - targetMs) < abs(rhs - targetMs)
        }
        guard let nearest, abs(nearest - targetMs) <= toleranceMs,
              let image = images.value(for: nearest) else {
            return nil
        }
        return (nearest, image)
    }

    func insert(_ image: DecodedImage, for timeMs: Int) {
        images.insert(image, for: timeMs, cost: decodedImageByteCost(image))
    }

    func clear() {
        images.removeAll()
    }
}
