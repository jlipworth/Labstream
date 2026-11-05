#if os(macOS)
import AppKit
import PMSKit
import SwiftUI
import Testing
@testable import Labstream

@Suite(.serialized)
@MainActor
struct MacMainWindowLifecycleTests {
    @Test
    func closeHidesAndReopenReusesTheRegisteredWindow() {
        let controller = MacMainWindowController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }
        let retainedContentView = window.contentView

        controller.register(window)
        window.orderFront(nil)
        #expect(window.isVisible)
        #expect(controller.mainWindow === window)
        #expect(window.standardWindowButton(.closeButton)?.target === controller)

        // Exercise NSWindow's real close path (also used by Command-W), not the controller
        // method directly.
        window.performClose(nil)
        #expect(!window.isVisible)
        #expect(controller.mainWindow === window)
        #expect(window.contentView === retainedContentView)

        controller.activateMainWindow()
        #expect(window.isVisible)
        #expect(controller.mainWindow === window)
        #expect(window.contentView === retainedContentView)
    }

    @Test
    func coldLaunchActivationWaitsForSwiftUIWindowRegistration() {
        let controller = MacMainWindowController()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.close() }

        controller.presentMainWindowWhenRegistered()
        #expect(!window.isVisible)

        controller.register(window)

        #expect(window.isVisible)
        #expect(controller.mainWindow === window)
    }

    @Test
    func closingTheOnlyWindowDoesNotTerminateTheApplication() {
        let delegate = MacAppDelegate()
        #expect(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        let didActivate = MacMainWindowController.shared.activateMainWindow()
        #expect(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false) == !didActivate)
    }

    @Test
    func commandsRemainQueuedUntilTheMainWindowConsumesThem() {
        let controller = MacMainWindowController()
        controller.issue(.focusSearch)
        controller.issue(.selectOffline)

        #expect(controller.pendingCommands.map(\.command) == [.focusSearch, .selectOffline])
        let first = controller.pendingCommands[0]
        controller.consume(first)
        #expect(controller.pendingCommands.map(\.command) == [.selectOffline])
    }

    @Test
    func resolvedSystemEntryDismissesTheRetainedPlayerOverlay() {
        let presenter = MacPlayerPresentationStore()
        presenter.present(ownerID: UUID(), contentID: "playing", onClose: {}) {
            EmptyView()
        }
        #expect(presenter.isPresented)

        presenter.dismissForResolvedSystemEntry()
        #expect(!presenter.isPresented)
    }

    @Test(arguments: [true, false])
    func closingVideoDismissesItsOwnerAndReopensBrowsing(usePerformClose: Bool) {
        let controller = MacMainWindowController()
        let presenter = MacPlayerPresentationStore(windowController: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.close() }
        var ownerIsPresenting = true
        var closeCount = 0
        presenter.present(ownerID: UUID(), contentID: "video", onClose: {
            ownerIsPresenting = false
            closeCount += 1
        }) { EmptyView() }
        controller.register(window)
        window.orderFront(nil)

        if usePerformClose {
            window.performClose(nil) // Command-W
        } else {
            window.standardWindowButton(.closeButton)?.performClick(nil) // red close button
        }
        #expect(!window.isVisible)
        #expect(!presenter.isPresented)
        #expect(!ownerIsPresenting)
        #expect(closeCount == 1)

        controller.activateMainWindow()
        #expect(window.isVisible)
        #expect(!presenter.isPresented)
        #expect(!ownerIsPresenting)
        controller.hideMainWindow(nil)
        #expect(closeCount == 1)
    }

    @Test
    func closingMountedPlayerRunsRealViewCleanup() async throws {
        let windowController = MacMainWindowController()
        let presenter = MacPlayerPresentationStore(windowController: windowController)
        let identity = PlatformClientIdentity.make(clientIdentifier: "mac-close-mounted-player")
        let model = AppModel(identity: identity)
        let artwork = ArtworkPipeline()
        let music = MusicPlayerController(appModel: model, artworkPipeline: artwork,
                                          resolveStream: { _, _ in
            throw MusicStreamResolver.ResolveError.notConnected
        })
        let item = MediaItem(ratingKey: "close-fixture", title: "Fixture", type: "movie",
                             duration: 60_000)
        var playback: PlaybackController?
        var closeSamples: [Int] = []
        presenter.present(ownerID: UUID(), contentID: "mounted-player", onClose: {}) {
            CustomPlayerView(item: item, controllerFactory: {
                let value = PlaybackController(
                    item: item,
                    sessionSource: .offline(OfflinePlaybackSession(
                        fileURL: URL(fileURLWithPath: "/fixture.invalid"),
                        onPlaybackClose: { position, _ in closeSamples.append(position) })),
                    identity: identity, client: PlexClient(identity: identity))
                playback = value
                return value
            })
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer {
            window.contentView = nil
            window.close()
            playback?.stop()
            music.stop()
        }
        window.contentView = NSHostingView(rootView:
            MacCloseMountedPlayerHost(presenter: presenter)
                .environment(model).environment(music).environment(\.artworkPipeline, artwork))
        windowController.register(window)
        window.orderFront(nil)
        let mountDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while playback == nil, ContinuousClock.now < mountDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let mountedPlayback = try #require(playback)
        #expect(!mountedPlayback.debugEvidenceSnapshot().cleanupRequested)
        window.performClose(nil)
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !mountedPlayback.debugEvidenceSnapshot().cleanupRequested,
              ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!window.isVisible)
        #expect(!presenter.isPresented)
        #expect(mountedPlayback.debugEvidenceSnapshot().cleanupRequested)
        #expect(!closeSamples.isEmpty)
        #expect(mountedPlayback.player.currentItem == nil)
    }

    @Test
    func activePictureInPictureSurvivesCloseAndReopenUntilItEnds() {
        let controller = MacMainWindowController()
        let presenter = MacPlayerPresentationStore(windowController: controller)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        defer { window.close() }
        var pipActive = true
        var closeCount = 0
        presenter.present(ownerID: UUID(), contentID: "video",
                          isPictureInPictureActive: { pipActive },
                          onClose: { closeCount += 1 }) { EmptyView() }
        controller.register(window)
        window.orderFront(nil)

        window.performClose(nil)
        #expect(!window.isVisible)
        #expect(presenter.isPresented)
        #expect(closeCount == 0)
        controller.activateMainWindow()
        #expect(window.isVisible)
        #expect(presenter.isPresented)

        pipActive = false
        window.performClose(nil)
        #expect(!presenter.isPresented)
        #expect(closeCount == 1)
    }

    @Test
    func closingWithoutVideoPreservesProcessOwnedMusicAndBrowsing() {
        let controller = MacMainWindowController()
        let presenter = MacPlayerPresentationStore(windowController: controller)
        let model = AppModel(identity: PlatformClientIdentity.make(clientIdentifier: "mac-close-music"))
        let music = MusicPlayerController(appModel: model, artworkPipeline: ArtworkPipeline(),
                                          resolveStream: { _, _ in
            // Keep the real music queue without any network or audio-device dependency.
            throw MusicStreamResolver.ResolveError.notConnected
        })
        defer { music.stop() }
        music.play(tracks: [MediaItem(ratingKey: "track", title: "Fixture", type: "track")],
                   startingAt: 0)
        let musicIntent = music.beginQueueIntent()
        // A dismissed video can leave the weak presenter registered. Neither this state nor
        // a controller with no presenter may trigger video cleanup or process-wide media stop.
        var closeCount = 0
        presenter.present(ownerID: UUID(), contentID: "finished",
                          onClose: { closeCount += 1 }) { EmptyView() }
        presenter.dismiss()
        controller.hideMainWindow(nil)
        #expect(closeCount == 0)
        #expect(!presenter.isPresented)
        #expect(music.queue.map(\.ratingKey) == ["track"])
        #expect(music.acceptsQueueIntent(musicIntent)) // stop() would revoke the intent and queue.
        #expect(controller.pendingCommands.isEmpty)
        MacMainWindowController().hideMainWindow(nil)
        #expect(!MacAppDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApp))
    }
}
private struct MacCloseMountedPlayerHost: View {
    let presenter: MacPlayerPresentationStore
    var body: some View {
        ZStack {
            Text("Browse")
            if let presentation = presenter.presentation {
                presentation.content
            }
        }
    }
}
#endif
