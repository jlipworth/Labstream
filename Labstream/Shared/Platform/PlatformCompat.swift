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

    static func copyPairingCode(_ string: String) { copy(string) }
}

enum PlatformAccessibility {
    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp,
                             notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high])
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
    static func copyPairingCode(_ string: String) {}
}
enum PlatformAccessibility { static func announce(_ message: String) {} }

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

    /// Pairing codes are credential-like and short lived. A user can intentionally paste into
    /// the browser on this device, but the value is neither synced through Universal Clipboard
    /// nor retained beyond the longest pairing window.
    static func copyPairingCode(_ string: String) {
        UIPasteboard.general.setItems(
            [["public.utf8-plain-text": string]],
            options: [.expirationDate: Date().addingTimeInterval(5 * 60), .localOnly: true])
    }
}
enum PlatformAccessibility {
    static func announce(_ message: String) {
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}
#endif
