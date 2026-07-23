import Foundation

/// Bounded decoded-image reuse for one Chapters panel session.
///
/// The cache deliberately stores only the opaque digest of the complete authenticated request.
/// It therefore distinguishes Plex query tokens and Jellyfin/Emby authorization headers without
/// retaining readable credentials. Ownership lives with `ChaptersTabView`: lazy cards may be
/// destroyed and recreated while the panel is open, and all decoded pixels are released when that
/// panel session ends. Memory pressure can release them sooner.
@MainActor
final class ChapterThumbnailImageCache {
    struct Limits: Sendable, Equatable {
        let maximumCount: Int
        let maximumPixelBytes: Int

        static let panelDefault = Limits(
            maximumCount: 48,
            maximumPixelBytes: 48 * 1_024 * 1_024
        )
    }

    private var images: CostBoundedLRU<SideAssetRequestKey, DecodedImage>
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(limits: Limits = .panelDefault, observesMemoryPressure: Bool = true) {
        precondition(limits.maximumCount > 0)
        precondition(limits.maximumPixelBytes > 0)
        images = CostBoundedLRU(
            costLimit: limits.maximumPixelBytes,
            countLimit: limits.maximumCount
        )

        if observesMemoryPressure {
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.warning, .critical],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.removeAll()
                }
            }
            source.resume()
            memoryPressureSource = source
        }
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    static func key(for request: URLRequest) -> SideAssetRequestKey {
        SideAssetRequestKey.authenticatedRequest(
            SideAssetTransportPolicy.nonpersistentRequest(request)
        )
    }

    /// Immediate lookup used while SwiftUI constructs a recreated card. The internal LRU touch
    /// publishes no observation state, so the very first frame can render warm.
    func peek(_ key: SideAssetRequestKey) -> DecodedImage? {
        images.value(for: key)
    }

    func image(for key: SideAssetRequestKey) -> DecodedImage? {
        images.value(for: key)
    }

    func insert(_ image: DecodedImage, for key: SideAssetRequestKey) {
        images.insert(image, for: key, cost: Self.estimatedPixelBytes(image))
    }

    func removeAll() {
        images.removeAll()
    }

    #if DEBUG
    var countForTesting: Int { images.count }
    var totalPixelBytesForTesting: Int { images.totalCost }
    #endif

    private static func estimatedPixelBytes(_ image: DecodedImage) -> Int {
        let bytesPerRow = max(image.cgImage.bytesPerRow, image.pixelWidth * 4)
        return max(1, bytesPerRow * image.pixelHeight)
    }
}

/// Testable loading seam shared by every lazy card recreation. The cache hit occurs before any
/// file read or coordinated transport, so warm back-scroll neither transfers nor decodes again.
@MainActor
enum ChapterThumbnailLoader {
    typealias DataLoader = @Sendable (URLRequest) async throws -> Data

    static func image(
        for request: URLRequest,
        cache: ChapterThumbnailImageCache,
        dataLoader: DataLoader = defaultDataLoader
    ) async throws -> DecodedImage? {
        try Task.checkCancellation()
        let key = ChapterThumbnailImageCache.key(for: request)
        if let cached = cache.image(for: key) {
            try Task.checkCancellation()
            return cached
        }

        let data = try await dataLoader(request)
        try Task.checkCancellation()
        guard let decoded = await DecodedImage.decodeEagerlyOffMain(data: data) else {
            return nil
        }
        try Task.checkCancellation()
        cache.insert(decoded, for: key)
        return decoded
    }

    private nonisolated static func defaultDataLoader(_ request: URLRequest) async throws -> Data {
        if let url = request.url, url.isFileURL {
            return try Data(contentsOf: url)
        }
        return try await SideAssetFetchCoordinator.shared.fetch(
            request: request,
            owner: SideAssetOwner(rawValue: "player-chapter-thumbnails")
        )
    }
}
