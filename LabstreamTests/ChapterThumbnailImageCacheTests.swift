import Foundation
import XCTest
@testable import Labstream

@MainActor
final class ChapterThumbnailImageCacheTests: XCTestCase {
    func testRecreatedLoaderReusesDecodedImageWithoutAnotherTransfer() async throws {
        let cache = ChapterThumbnailImageCache(
            limits: .init(maximumCount: 8, maximumPixelBytes: 1_024 * 1_024),
            observesMemoryPressure: false
        )
        let transfers = ChapterThumbnailTransferCounter()
        var request = URLRequest(url: URL(
            string: "https://plex.example/photo?X-Plex-Token=private-token"
        )!)
        request.setValue("Bearer private-header", forHTTPHeaderField: "Authorization")

        let firstResult = try await ChapterThumbnailLoader.image(
            for: request,
            cache: cache,
            dataLoader: { _ in
                await transfers.increment()
                return Self.onePixelPNG
            }
        )
        let first = try XCTUnwrap(firstResult)

        // Model the `LazyHStack` destroying the first view and creating a new loader with only the
        // panel cache in common. Its transport closure must never be entered.
        let recreatedResult = try await ChapterThumbnailLoader.image(
            for: request,
            cache: cache,
            dataLoader: { _ in
                await transfers.increment()
                return Self.onePixelPNG
            }
        )
        let recreated = try XCTUnwrap(recreatedResult)

        XCTAssertTrue(first === recreated, "the decoded object itself must be reused")
        let transferCount = await transfers.value
        XCTAssertEqual(transferCount, 1)
        XCTAssertTrue(cache.peek(ChapterThumbnailImageCache.key(for: request)) === first)
    }

    func testAuthenticatedContextsHaveDistinctOpaqueCacheKeys() async throws {
        var first = URLRequest(url: URL(string: "https://jellyfin.example/Items/1/Images/Chapter")!)
        first.setValue("MediaBrowser Token=first-secret", forHTTPHeaderField: "Authorization")
        var second = first
        second.setValue("MediaBrowser Token=second-secret", forHTTPHeaderField: "Authorization")

        let firstKey = ChapterThumbnailImageCache.key(for: first)
        let secondKey = ChapterThumbnailImageCache.key(for: second)
        XCTAssertNotEqual(firstKey, secondKey)
        for secret in ["first-secret", "second-secret", "jellyfin.example"] {
            XCTAssertFalse(firstKey.rawValue.contains(secret))
            XCTAssertFalse(secondKey.rawValue.contains(secret))
        }
    }

    func testLocalFileIsDecodedOnceAndRemainsWarmAfterFileDisappears() async throws {
        let cache = ChapterThumbnailImageCache(
            limits: .init(maximumCount: 8, maximumPixelBytes: 1_024 * 1_024),
            observesMemoryPressure: false
        )
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("chapter-\(UUID().uuidString).png")
        try Self.onePixelPNG.write(to: file)
        let request = URLRequest(url: file)

        let firstResult = try await ChapterThumbnailLoader.image(
            for: request, cache: cache
        )
        let first = try XCTUnwrap(firstResult)
        try FileManager.default.removeItem(at: file)
        let recreatedResult = try await ChapterThumbnailLoader.image(
            for: request, cache: cache
        )
        let recreated = try XCTUnwrap(recreatedResult)

        XCTAssertTrue(first === recreated)
    }

    func testCountBoundEvictsLeastRecentlyUsedDecodedImage() {
        let cache = ChapterThumbnailImageCache(
            limits: .init(maximumCount: 2, maximumPixelBytes: 1_024 * 1_024),
            observesMemoryPressure: false
        )
        let image = DecodedImage(data: Self.onePixelPNG)!
        let keys = (0..<3).map { SideAssetRequestKey(rawValue: "opaque-\($0)") }
        cache.insert(image, for: keys[0])
        cache.insert(image, for: keys[1])
        XCTAssertNotNil(cache.image(for: keys[0])) // key 1 is now least-recently-used.
        cache.insert(image, for: keys[2])

        XCTAssertNotNil(cache.peek(keys[0]))
        XCTAssertNil(cache.peek(keys[1]))
        XCTAssertNotNil(cache.peek(keys[2]))
        XCTAssertEqual(cache.countForTesting, 2)
    }

    func testLifecycleOrMemoryPressureReleaseDropsAllDecodedImages() {
        let cache = ChapterThumbnailImageCache(
            limits: .init(maximumCount: 8, maximumPixelBytes: 1_024 * 1_024),
            observesMemoryPressure: false
        )
        cache.insert(
            DecodedImage(data: Self.onePixelPNG)!,
            for: SideAssetRequestKey(rawValue: "opaque")
        )
        XCTAssertEqual(cache.countForTesting, 1)
        cache.removeAll()
        XCTAssertEqual(cache.countForTesting, 0)
        XCTAssertEqual(cache.totalPixelBytesForTesting, 0)
    }

    private nonisolated static let onePixelPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )!
}

private actor ChapterThumbnailTransferCounter {
    private var count = 0
    func increment() { count += 1 }
    var value: Int { count }
}
