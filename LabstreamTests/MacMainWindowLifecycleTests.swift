#if os(macOS)
import AppKit
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
        presenter.present(ownerID: UUID(), contentID: "playing") {
            EmptyView()
        }
        #expect(presenter.isPresented)

        presenter.dismissForResolvedSystemEntry()
        #expect(!presenter.isPresented)
    }
}
#endif
