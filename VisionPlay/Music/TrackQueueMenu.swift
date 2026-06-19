import SwiftUI
import PMSKit

/// Shared context-menu content for one FULL track row (has Media/Part — album
/// tracks, popular tracks): the #17 Phase-4 queue actions. Search rows are
/// skinny and re-fetch metadata first, so they build their own menu.
///
/// The controller is passed explicitly rather than via @Environment so the menu
/// keeps working wherever a context menu materializes its content.
struct TrackQueueMenu: View {
    let track: MediaItem
    let player: MusicPlayerController

    var body: some View {
        Button {
            player.playNext([track])
        } label: {
            Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
        }
        Button {
            player.addToQueue([track])
        } label: {
            Label("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward")
        }
    }
}
