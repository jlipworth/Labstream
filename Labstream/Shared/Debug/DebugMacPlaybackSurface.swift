#if DEBUG && os(macOS)
import AppKit

/// A real, isolated render surface for explicitly admitted native playback probes.
/// The normal player host supplies screen diagnostics; no display capability is invented.
@MainActor
final class DebugMacPlaybackSurface {
    private let window: NSWindow
    private let host: PlayerLayerHostView
    private weak var controller: PlaybackController?

    init(controller: PlaybackController) {
        self.controller = controller
        host = PlayerLayerHostView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Labstream Dev — Playback evidence"
        window.contentView = host
        host.setPlayer(controller.player)
        host.displayDiagnostics = controller.diagnostics
        window.center()
        window.makeKeyAndOrderFront(nil)
        controller.debugVisibleAttachmentCount += 1
        controller.debugVisibleWindowIsVisible = { [weak window] in window?.isVisible == true }
    }

    func close() {
        guard let controller else { return }
        self.controller = nil
        controller.debugVisibleAttachmentCount = max(0, controller.debugVisibleAttachmentCount - 1)
        controller.debugVisibleWindowIsVisible = nil
        host.stopDisplayObservation()
        host.setPlayer(nil)
        window.orderOut(nil)
        window.close()
    }
}
#endif
