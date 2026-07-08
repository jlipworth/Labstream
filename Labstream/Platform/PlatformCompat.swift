import Foundation
import SwiftUI

#if os(macOS)
import AppKit
import AVFoundation

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

// Minimal MediaPlayer stand-ins used by the shared music code until a Mac Now Playing
// implementation is designed. These are intentionally inert.
let MPMediaItemPropertyTitle = "title"
let MPMediaItemPropertyPlaybackDuration = "duration"
let MPMediaItemPropertyArtist = "artist"
let MPMediaItemPropertyAlbumTitle = "albumTitle"
let MPMediaItemPropertyArtwork = "artwork"
let MPNowPlayingInfoPropertyElapsedPlaybackTime = "elapsedPlaybackTime"
let MPNowPlayingInfoPropertyPlaybackRate = "playbackRate"

struct MPMediaItemArtwork {
    let boundsSize: CGSize
    init(boundsSize: CGSize, requestHandler: @escaping (CGSize) -> UIImage) {
        self.boundsSize = boundsSize
    }
}

@MainActor
final class MPNowPlayingInfoCenter {
    static let shared = MPNowPlayingInfoCenter()
    class func `default`() -> MPNowPlayingInfoCenter { shared }
    var nowPlayingInfo: [String: Any]?
}

class MPRemoteCommandEvent {}
final class MPChangePlaybackPositionCommandEvent: MPRemoteCommandEvent {
    let positionTime: TimeInterval
    init(positionTime: TimeInterval) { self.positionTime = positionTime }
}

enum MPRemoteCommandHandlerStatus {
    case success
    case noActionableNowPlayingItem
    case commandFailed
}

@MainActor
final class MPRemoteCommand {
    var isEnabled = true
    @discardableResult
    func addTarget(_ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) -> Any {
        UUID()
    }
    func removeTarget(_ target: Any?) {}
}

@MainActor
final class MPRemoteCommandCenter {
    static let sharedCenter = MPRemoteCommandCenter()
    class func shared() -> MPRemoteCommandCenter { sharedCenter }
    let playCommand = MPRemoteCommand()
    let pauseCommand = MPRemoteCommand()
    let togglePlayPauseCommand = MPRemoteCommand()
    let nextTrackCommand = MPRemoteCommand()
    let previousTrackCommand = MPRemoteCommand()
    let changePlaybackPositionCommand = MPRemoteCommand()
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
