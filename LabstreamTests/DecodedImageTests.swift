import CoreGraphics
import Foundation
import ImageIO
import PMSKit
import XCTest
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
@testable import Labstream

final class DecodedImageTests: XCTestCase {
    func testSharedImageCallSitesUseExplicitDecodedBoundary() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let compatibilitySource = try String(
            contentsOf: root.appendingPathComponent("Labstream/Shared/Platform/PlatformCompat.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(compatibilitySource.contains("typealias UIImage = NSImage"))
        XCTAssertFalse(compatibilitySource.contains("extension NSImage"))

        let migratedFiles = [
            "Labstream/Shared/UI/PosterImage.swift",
            "Labstream/Shared/Player/PlayerControlPickers.swift",
            "Labstream/Shared/Player/TrickPlayThumbnailProviders.swift",
            "Labstream/Shared/Player/CustomPlayerChrome.swift",
            "Labstream/Shared/Player/VideoNowPlayingCore.swift",
            "Labstream/Shared/Player/NowPlayingArtwork.swift",
            "Labstream/Shared/Music/MusicPlayerController.swift",
            "Labstream/Capabilities/Downloads/Core/OfflineLibraryView.swift",
            "Labstream/Platforms/visionOS/Player/VideoNowPlayingCoordinator.swift",
        ]
        for path in migratedFiles {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("UIImage(data:"), "Native decode escaped into \(path)")
            XCTAssertFalse(source.contains("NSImage(data:"), "Native decode escaped into \(path)")
            XCTAssertFalse(source.contains("Image(uiImage:"), "UIKit rendering escaped into \(path)")
        }
    }

    func testJellyfinTileCropPreservesExactPixels() throws {
        let sheet = DecodedImage(cgImage: try makeTwoColorImage(width: 4, height: 2))
        let tile = JellyfinTrickPlayTile(uri: "sheet.jpg",
                                        startMs: 0,
                                        durationMs: 2_000,
                                        tileDurationMs: 1_000,
                                        tileWidth: 2,
                                        tileHeight: 2,
                                        columns: 2,
                                        rows: 1)
        let frame = try XCTUnwrap(JellyfinTrickPlayPlaylist(tiles: [tile]).frame(nearMs: 1_500))

        let cropped = try XCTUnwrap(JellyfinTrickPlayTileRenderer.crop(sheet: sheet, frame: frame))

        XCTAssertEqual(cropped.pixelWidth, 2)
        XCTAssertEqual(cropped.pixelHeight, 2)
        let (red, green, blue) = try centerRGB(cropped.cgImage)
        XCTAssertGreaterThan(Int(blue), max(Int(red), Int(green)) * 3,
                             "Second tile should retain blue pixels, got r=\(red) g=\(green) b=\(blue)")
    }

    func testDecodeAndJPEGEncodePreserveOrientationMetadata() throws {
        let sourceImage = try makeTwoColorImage(width: 3, height: 2)
        let encoded = try XCTUnwrap(encode(sourceImage,
                                           type: "public.png" as CFString,
                                           orientation: .right))

        let decoded = try XCTUnwrap(DecodedImage(data: encoded))

        XCTAssertEqual(decoded.pixelWidth, 3)
        XCTAssertEqual(decoded.pixelHeight, 2)
        XCTAssertEqual(decoded.orientation, CGImagePropertyOrientation.right)
        XCTAssertEqual(decoded.displayPixelSize, CGSize(width: 2, height: 3))
        XCTAssertEqual(decoded.displayCGImage.width, 2)
        XCTAssertEqual(decoded.displayCGImage.height, 3)

        let jpeg = try XCTUnwrap(decoded.jpegData(compressionQuality: 0.8))
        let roundTripped = try XCTUnwrap(DecodedImage(data: jpeg))
        XCTAssertEqual(roundTripped.orientation, CGImagePropertyOrientation.right)
        XCTAssertEqual(roundTripped.pixelWidth, 3)
        XCTAssertEqual(roundTripped.pixelHeight, 2)
    }

    func testPlatformBridgePreservesPointSize() throws {
        let decoded = DecodedImage(cgImage: try makeTwoColorImage(width: 4, height: 2),
                                   scale: 2,
                                   orientation: .right)

        let platformImage: PlatformImage = decoded.platformImage

        XCTAssertEqual(platformImage.size.width, 1, accuracy: 0.001)
        XCTAssertEqual(platformImage.size.height, 2, accuracy: 0.001)
    }

    func testOrientedDisplayImagePreservesColorSpaceAndComponentDepth() throws {
        let displayP3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let source = try makeTwoColor16BitImage(width: 4, height: 2, colorSpace: displayP3)
        let decoded = DecodedImage(cgImage: source, orientation: .right)

        let displayed = decoded.displayCGImage

        XCTAssertEqual(displayed.width, 2)
        XCTAssertEqual(displayed.height, 4)
        XCTAssertEqual(displayed.bitsPerComponent, source.bitsPerComponent)
        XCTAssertEqual(displayed.colorSpace?.name, source.colorSpace?.name)
    }

    func testOrientedCMYKDisplayImageUsesTaggedRGBFallback() throws {
        let source = try makeCMYKImage(width: 4, height: 2)
        let decoded = DecodedImage(cgImage: source, orientation: .right)

        let displayed = decoded.displayCGImage

        XCTAssertEqual(displayed.width, 2)
        XCTAssertEqual(displayed.height, 4)
        XCTAssertEqual(displayed.bitsPerComponent, 8)
        XCTAssertEqual(displayed.colorSpace?.name, CGColorSpace.sRGB)
    }

    func testInvalidDataDoesNotCreateDecodedImage() {
        XCTAssertNil(DecodedImage(data: Data("not-an-image".utf8)))
    }

    @MainActor
    func testEagerDecodeUsesDetachedQueueAndPreservesImageFacts() async throws {
        let sourceImage = try makeTwoColorImage(width: 3, height: 2)
        let encoded = try XCTUnwrap(encode(sourceImage,
                                           type: "public.png" as CFString,
                                           orientation: .right))

        let executorProbe = LockedDecodeExecutorProbe()
        let result = await DecodedImage.decodeEagerlyOffMain(
            data: encoded,
            scale: 2,
            executorProbe: {
                dispatchPrecondition(condition: .notOnQueue(.main))
                executorProbe.recordExecution()
            }
        )
        XCTAssertTrue(executorProbe.didExecute)
        let decoded = try XCTUnwrap(result)

        XCTAssertEqual(decoded.pixelWidth, 3)
        XCTAssertEqual(decoded.pixelHeight, 2)
        XCTAssertEqual(decoded.orientation, .right)
        XCTAssertEqual(decoded.scale, 2)
        XCTAssertGreaterThan(decoded.cgImage.bytesPerRow * decoded.cgImage.height, 0)
    }

    func testCancelledEagerDecodeDoesNotPublishImage() async throws {
        let encoded = try XCTUnwrap(encode(try makeTwoColorImage(width: 3, height: 2),
                                           type: "public.png" as CFString,
                                           orientation: .up))
        let task = Task {
            await Task.yield()
            return await DecodedImage.decodeEagerlyOffMain(data: encoded)
        }
        task.cancel()

        let result = await task.value
        XCTAssertNil(result)
    }

    private func makeTwoColorImage(width: Int,
                                   height: Int,
                                   colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()) throws -> CGImage {
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
            | CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try XCTUnwrap(CGContext(data: nil,
                                              width: width,
                                              height: height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: width * 4,
                                              space: colorSpace,
                                              bitmapInfo: bitmapInfo))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTwoColor16BitImage(width: Int,
                                        height: Int,
                                        colorSpace: CGColorSpace) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 16,
            bytesPerRow: width * 8,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder16Little.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [0, 0, 1, 1])!)
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeCMYKImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceCMYK()
        let context = try XCTUnwrap(CGContext(data: nil,
                                              width: width,
                                              height: height,
                                              bitsPerComponent: 8,
                                              bytesPerRow: width * 4,
                                              space: colorSpace,
                                              bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 0, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func centerRGB(_ image: CGImage) throws -> (UInt8, UInt8, UInt8) {
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress,
                                                  width: 1,
                                                  height: 1,
                                                  bitsPerComponent: 8,
                                                  bytesPerRow: 4,
                                                  space: CGColorSpaceCreateDeviceRGB(),
                                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                                                    | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return (bytes[0], bytes[1], bytes[2])
    }

    private func encode(_ image: CGImage,
                        type: CFString,
                        orientation: CGImagePropertyOrientation) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyOrientation: orientation.rawValue,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

private final class LockedDecodeExecutorProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var executed = false

    var didExecute: Bool {
        lock.withLock { executed }
    }

    func recordExecution() {
        lock.withLock { executed = true }
    }
}
