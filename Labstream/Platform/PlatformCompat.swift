import Foundation
import SwiftUI

#if os(macOS)
import AppKit
import AVFoundation
import MediaPlayer

/// Lightweight native-image compatibility for the first macOS slice.
///
/// Most artwork code is still UIImage-shaped. The target now builds native macOS by
/// aliasing those image values to `NSImage`, while future feature agents can replace
/// call sites with the `PlatformImage` spelling as they deepen Mac polish.
typealias PlatformImage = NSImage
typealias UIImage = NSImage

extension Image {
    init(uiImage: UIImage) {
        self.init(nsImage: uiImage)
    }
}

extension NSImage {
    typealias Orientation = Int

    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    var scale: CGFloat { 1 }
    var imageOrientation: Orientation { 0 }

    convenience init(cgImage: CGImage, scale: CGFloat, orientation: Orientation) {
        let size = CGSize(width: CGFloat(cgImage.width) / max(scale, 1),
                          height: CGFloat(cgImage.height) / max(scale, 1))
        self.init(cgImage: cgImage, size: size)
    }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}

/// Pasteboard adapter so diagnostics/feedback code does not import UIKit on macOS.
enum PlatformPasteboard {
    static func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

/// macOS does not expose AVAudioSession. Keep call sites typed and make the policy a no-op.
enum PlatformAudioSessionMode {
    case `default`
    case moviePlayback
}

#elseif os(tvOS)
import UIKit
import AVFAudio

typealias PlatformImage = UIImage
typealias PlatformAudioSessionMode = AVAudioSession.Mode

/// tvOS has no general pasteboard. Feedback UI must use a TV-native handoff;
/// this compatibility seam deliberately performs no copy operation.
enum PlatformPasteboard {
    static func copy(_ string: String) {}
}

#elseif canImport(UIKit)
import UIKit
import AVFAudio

typealias PlatformImage = UIImage
typealias PlatformAudioSessionMode = AVAudioSession.Mode

enum PlatformPasteboard {
    static func copy(_ string: String) {
        UIPasteboard.general.string = string
    }
}
#endif
