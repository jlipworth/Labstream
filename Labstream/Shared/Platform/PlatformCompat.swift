import Foundation
import SwiftUI

#if os(macOS)
import AppKit
import AVFoundation
import MediaPlayer

/// Native image values are allowed only at platform-framework boundaries. Shared artwork
/// decode, crop, cache, and SwiftUI presentation use `DecodedImage` instead.
typealias PlatformImage = NSImage

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

/// Native image values are allowed only at platform-framework boundaries. Shared artwork
/// decode, crop, cache, and SwiftUI presentation use `DecodedImage` instead.
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

/// Native image values are allowed only at platform-framework boundaries. Shared artwork
/// decode, crop, cache, and SwiftUI presentation use `DecodedImage` instead.
typealias PlatformImage = UIImage
typealias PlatformAudioSessionMode = AVAudioSession.Mode

enum PlatformPasteboard {
    static func copy(_ string: String) {
        UIPasteboard.general.string = string
    }
}
#endif
