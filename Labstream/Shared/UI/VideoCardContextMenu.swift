import SwiftUI
import PMSKit

/// Long-press / context menu shared by every VIDEO media card (movie/show/season/episode
/// poster or grid cell) across Home, Libraries, and Search. visionOS surfaces it on
/// long-pinch and iPad on long-press, so no platform gating is needed.
///
/// Music cards are intentionally skipped: they route into the music module and already
/// carry their own row menus (the Search Songs list), so a "Mark Watched" action would be
/// meaningless there.
///
/// The action set is deliberately small and correct — a big broken menu is worse than a
/// small working one:
///   • Mark Watched / Mark Unwatched — scrobbles against the active backend through the
///     same `DetailWatchedUpdater` the detail screen uses, flipping an optimistic local
///     flag so the label reflects the change the next time the menu opens.
///   • Go to Show — episodes only, and only when the environment supplies a push closure
///     (the browse tabs do) and the episode carries its show's grandparent keys.
private struct VideoCardContextMenu: ViewModifier {
    let item: MediaItem

    @Environment(AppModel.self) private var appModel
    @Environment(\.pushMediaItem) private var pushMediaItem

    /// Optimistic watched state; `nil` defers to the item's own `viewCount`.
    @State private var watchedOverride: Bool?
    @State private var isToggling = false

    func body(content: Content) -> some View {
        // Music items route elsewhere and never own a watched/show action.
        if item.isMusic {
            content
        } else {
            content.contextMenu {
                Button {
                    toggleWatched()
                } label: {
                    Label(isWatched ? "Mark Unwatched" : "Mark Watched",
                          systemImage: isWatched ? "minus.circle" : "checkmark.circle")
                }
                .disabled(isToggling)

                if item.kind == .episode, let show = showItem, let pushMediaItem {
                    Button {
                        pushMediaItem(show)
                    } label: {
                        Label("Go to Show", systemImage: "tv")
                    }
                }
            }
        }
    }

    private var isWatched: Bool {
        watchedOverride ?? ((item.viewCount ?? 0) > 0)
    }

    /// The episode's show as a pushable container item (show = grandparent), mirroring
    /// `DetailView.showItem`. `nil` when the payload lacks the grandparent keys.
    private var showItem: MediaItem? {
        guard let key = item.grandparentRatingKey,
              let title = item.grandparentTitle else { return nil }
        return MediaItem(ratingKey: key, title: title, type: "show",
                         thumb: item.grandparentThumb)
    }

    /// Flip the optimistic flag immediately, then scrobble/unscrobble against the active
    /// backend; roll the flag back on failure. Mirrors `DetailView.toggleWatched`.
    private func toggleWatched() {
        guard !isToggling else { return }
        isToggling = true
        let played = !isWatched
        watchedOverride = played
        Task { @MainActor in
            defer { isToggling = false }
            do {
                try await DetailWatchedUpdater.setPlayed(item: item,
                                                         backend: appModel.activeBackend,
                                                         appModel: appModel,
                                                         played: played)
            } catch {
                watchedOverride = !played
            }
        }
    }
}

extension View {
    /// Attach the shared video-card context menu (Mark Watched / Go to Show). No-op for
    /// music items. See ``VideoCardContextMenu``.
    func videoCardContextMenu(for item: MediaItem) -> some View {
        modifier(VideoCardContextMenu(item: item))
    }
}

// MARK: - Push environment

/// Environment closure that pushes a `MediaItem` onto the current browse tab's navigation
/// path. `RootView` injects one per browse stack (Home/Libraries/Search — each with its
/// own lifted path), so a cell-level context menu can navigate (e.g. "Go to Show") without
/// threading a `NavigationPath` binding through every rail/grid view. `nil` where no stack
/// provides one, in which case navigation actions are simply omitted.
struct PushMediaItemKey: EnvironmentKey {
    static let defaultValue: (@MainActor (MediaItem) -> Void)? = nil
}

extension EnvironmentValues {
    var pushMediaItem: (@MainActor (MediaItem) -> Void)? {
        get { self[PushMediaItemKey.self] }
        set { self[PushMediaItemKey.self] = newValue }
    }
}
