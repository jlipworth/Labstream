import AppKit
import SwiftUI

/// Window-scoped presentation host for the native macOS player.
///
/// Detail/offline surfaces still own playback resolution and controller construction, but the
/// rendered player is lifted to `RootView` so it can cover the full window instead of being boxed
/// inside a `NavigationSplitView` detail column.
@MainActor
@Observable
final class MacPlayerPresentationStore {
    private(set) var presentation: MacPlayerPresentation?

    var isPresented: Bool {
        presentation != nil
    }

    func present<Content: View>(ownerID: UUID,
                                contentID: AnyHashable,
                                @ViewBuilder content: () -> Content) {
        presentation = MacPlayerPresentation(ownerID: ownerID,
                                             contentID: contentID,
                                             content: AnyView(content()))
    }

    func dismiss(ownerID: UUID? = nil) {
        guard ownerID == nil || presentation?.ownerID == ownerID else { return }
        presentation = nil
    }

    /// A successfully resolved App Intent/Spotlight route replaces any currently presented Mac
    /// player so the requested detail becomes visible. Callers must invoke this only after target
    /// resolution succeeds; an invalid/stale route deliberately leaves active playback untouched.
    func dismissForResolvedSystemEntry() {
        presentation = nil
    }
}

struct MacPlayerPresentation: Identifiable {
    let ownerID: UUID
    let contentID: AnyHashable
    let content: AnyView

    var id: UUID { ownerID }
}

private struct MacPlayerPresentationStoreKey: EnvironmentKey {
    static let defaultValue: MacPlayerPresentationStore? = nil
}

extension EnvironmentValues {
    var macPlayerPresentationStore: MacPlayerPresentationStore? {
        get { self[MacPlayerPresentationStoreKey.self] }
        set { self[MacPlayerPresentationStoreKey.self] = newValue }
    }
}

/// AppKit bridge used while the player overlay is active to remove the normal app toolbar
/// (Search/Offline/sidebar chrome) from the titlebar. Traffic-light window controls remain
/// system-owned; the player chrome adds its own leading inset so its Close button never sits
/// beneath them.
struct MacWindowToolbarVisibilityController: NSViewRepresentable {
    let hidesToolbar: Bool

    func makeNSView(context: Context) -> MacWindowToolbarVisibilityHostView {
        let view = MacWindowToolbarVisibilityHostView()
        view.hidesToolbar = hidesToolbar
        return view
    }

    func updateNSView(_ nsView: MacWindowToolbarVisibilityHostView, context: Context) {
        nsView.hidesToolbar = hidesToolbar
        nsView.applyToolbarVisibility()
    }

    static func dismantleNSView(_ nsView: MacWindowToolbarVisibilityHostView, coordinator: ()) {
        nsView.restoreToolbarVisibility()
    }
}

final class MacWindowToolbarVisibilityHostView: NSView {
    var hidesToolbar = false {
        didSet {
            applyToolbarVisibility()
        }
    }

    private weak var appliedWindow: NSWindow?
    private var previousToolbarVisibility: Bool?
    private var previousTitleVisibility: NSWindow.TitleVisibility?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyToolbarVisibility()
    }

    func applyToolbarVisibility() {
        guard let window else {
            restoreToolbarVisibility()
            return
        }

        if appliedWindow !== window {
            restoreToolbarVisibility()
            appliedWindow = window
        }

        if hidesToolbar {
            if previousTitleVisibility == nil {
                previousTitleVisibility = window.titleVisibility
            }
            window.titleVisibility = .hidden

            guard let toolbar = window.toolbar else { return }
            if previousToolbarVisibility == nil {
                previousToolbarVisibility = toolbar.isVisible
            }
            toolbar.isVisible = false
        } else {
            restoreToolbarVisibility()
        }
    }

    func restoreToolbarVisibility() {
        if let appliedWindow {
            if let previousToolbarVisibility,
               let toolbar = appliedWindow.toolbar {
                toolbar.isVisible = previousToolbarVisibility
            }
            if let previousTitleVisibility {
                appliedWindow.titleVisibility = previousTitleVisibility
            }
        }
        previousToolbarVisibility = nil
        previousTitleVisibility = nil
        appliedWindow = nil
    }
}
