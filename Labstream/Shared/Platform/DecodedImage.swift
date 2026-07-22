import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import SwiftUI

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Immutable, platform-neutral result of decoding an image.
///
/// Shared code owns pixels and orientation explicitly instead of pretending AppKit's
/// `NSImage` has UIKit's `UIImage` semantics. Conversion to a native platform image is
/// deliberately confined to `platformImage`, which exists for framework APIs such as
/// `MPMediaItemArtwork`; SwiftUI renders the `CGImage` directly.
final class DecodedImage: Sendable {
    let cgImage: CGImage
    let scale: CGFloat
    let orientation: CGImagePropertyOrientation

    init(cgImage: CGImage,
         scale: CGFloat = 1,
         orientation: CGImagePropertyOrientation = .up) {
        self.cgImage = cgImage
        self.scale = scale.isFinite && scale > 0 ? scale : 1
        self.orientation = orientation
    }

    convenience init?(data: Data, scale: CGFloat = 1) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        self.init(cgImage: image,
                  scale: scale,
                  orientation: CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up)
    }

    var pixelWidth: Int { cgImage.width }
    var pixelHeight: Int { cgImage.height }

    var displayPixelSize: CGSize {
        orientation.swapsAxes
            ? CGSize(width: pixelHeight, height: pixelWidth)
            : CGSize(width: pixelWidth, height: pixelHeight)
    }

    /// Native image conversion is a platform-framework bridge, not shared image storage.
    var platformImage: PlatformImage {
        #if os(macOS)
        let displayed = displayCGImage
        return NSImage(cgImage: displayed,
                       size: CGSize(width: CGFloat(displayed.width) / scale,
                                    height: CGFloat(displayed.height) / scale))
        #else
        return UIImage(cgImage: cgImage,
                       scale: scale,
                       orientation: orientation.uiImageOrientation)
        #endif
    }

    /// Pixel representation with EXIF orientation applied. Kept internal so focused tests can
    /// verify the bridge without exposing native AppKit/UIKit behavior to shared consumers.
    var displayCGImage: CGImage {
        guard orientation != .up else { return cgImage }
        let oriented = CIImage(cgImage: cgImage).oriented(orientation)
        return Self.orientationContext.createCGImage(oriented,
                                                     from: oriented.extent,
                                                     format: orientationOutputFormat,
                                                     colorSpace: orientationOutputColorSpace) ?? cgImage
    }

    /// Preserve the existing trick-play contract: crop output is JPEG data at the requested
    /// quality, with orientation carried as standard image metadata.
    func jpegData(compressionQuality: CGFloat) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.jpeg" as CFString,
            1,
            nil
        ) else { return nil }
        let quality = min(max(compressionQuality, 0), 1)
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImagePropertyOrientation: orientation.rawValue,
        ]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static let orientationContext = CIContext(options: [
        .cacheIntermediates: false,
    ])

    private var orientationOutputColorSpace: CGColorSpace? {
        guard let sourceColorSpace = cgImage.colorSpace else { return nil }
        switch sourceColorSpace.model {
        case .rgb, .monochrome:
            return sourceColorSpace
        default:
            // Core Image's output formats are RGB/luminance. Tag unavoidable conversions from
            // CMYK/indexed sources instead of returning an unprofiled raster.
            return CGColorSpace(name: CGColorSpace.sRGB)
        }
    }

    private var orientationOutputFormat: CIFormat {
        let isMonochrome = cgImage.colorSpace?.model == .monochrome
        let isFloat = cgImage.bitmapInfo.contains(.floatComponents)

        switch (cgImage.bitsPerComponent, isFloat, isMonochrome) {
        case (let depth, true, true) where depth <= 16: return CIFormat.LAh
        case (_, true, true): return CIFormat.LAf
        case (let depth, true, false) where depth <= 16: return CIFormat.RGBAh
        case (_, true, false): return CIFormat.RGBAf
        case (let depth, false, true) where depth > 8: return CIFormat.LA16
        case (_, false, true): return CIFormat.LA8
        case (let depth, false, false) where depth > 8: return CIFormat.RGBA16
        case (_, false, false): return CIFormat.RGBA8
        }
    }
}

extension Image {
    init(decodedImage: DecodedImage) {
        self.init(decorative: decodedImage.cgImage,
                  scale: decodedImage.scale,
                  orientation: decodedImage.orientation.swiftUIOrientation)
    }
}

private extension CGImagePropertyOrientation {
    var swapsAxes: Bool {
        switch self {
        case .left, .leftMirrored, .right, .rightMirrored:
            true
        default:
            false
        }
    }

    var swiftUIOrientation: Image.Orientation {
        switch self {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }

    #if canImport(UIKit)
    var uiImageOrientation: UIImage.Orientation {
        switch self {
        case .up: .up
        case .upMirrored: .upMirrored
        case .down: .down
        case .downMirrored: .downMirrored
        case .left: .left
        case .leftMirrored: .leftMirrored
        case .right: .right
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
    #endif
}
