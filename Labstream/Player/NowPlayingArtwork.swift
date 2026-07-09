import MediaPlayer
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// `MPMediaItemArtwork`'s image request handler is invoked on MediaPlayer's own serial queue
/// (e.g. while serializing Now Playing info), so it must NOT be actor-isolated — a closure formed
/// inside a `@MainActor` type inherits MainActor isolation and the runtime's
/// dispatch_assert_queue check SIGTRAPs (seen live: crash on first song). Every Now Playing
/// surface (music, mobile video, Mac video) must build artwork through this single nonisolated
/// factory so the constraint cannot be lost in a copy.
enum NowPlayingArtwork {
    nonisolated static func make(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
