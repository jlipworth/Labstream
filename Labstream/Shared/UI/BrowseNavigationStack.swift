import PMSKit
import SwiftUI

/// The session-scoped stack boundary shared by every native shell.
///
/// Shells retain their native layout and choose their own root content. This helper centralizes
/// only the invariants that were repeated for every online destination: exact-session identity and
/// the context-menu push action.
struct BrowseNavigationStack<Content: View>: View {
  @Binding private var path: NavigationPath
  private let sessionKey: String
  private let onPush: @MainActor (MediaItem) -> Void
  private let content: Content

  init(
    path: Binding<NavigationPath>,
    sessionKey: String,
    onPush: @escaping @MainActor (MediaItem) -> Void,
    @ViewBuilder content: () -> Content
  ) {
    _path = path
    self.sessionKey = sessionKey
    self.onPush = onPush
    self.content = content()
  }

  var body: some View {
    NavigationStack(path: $path) {
      content
    }
    .environment(\.pushMediaItem, onPush)
    .id(sessionKey)
  }
}
