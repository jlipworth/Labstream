import PMSKit
import SwiftUI

/// visionOS tab shell, including the scene ornament, deterministic Now Playing backdrop, Cinema
/// origin tagging, and SharePlay prompt. Cinema itself remains owned by the visionOS app scenes.
struct PlatformRootShell: View {
  let runtime: AppRuntime
  @Bindable var navigation: RootNavigationCoordinator

  @Environment(WatchTogetherCoordinator.self) private var watchTogetherCoordinator

  private var appModel: AppModel { runtime.appModel }
  private var authManager: AuthManager { runtime.authManager }
  private var downloadManager: DownloadManager { runtime.downloadManager }

  var body: some View {
    tabs
      // The custom presentation must make the obscured hierarchy inert; otherwise gaze/pinch
      // can fall through its full-window backdrop.
      .allowsHitTesting(!navigation.nowPlayingPresentation.isPresented)
      .overlay {
        if navigation.nowPlayingPresentation.isPresented {
          ZStack {
            Button {
              navigation.nowPlayingPresentation.dismiss()
            } label: {
              Rectangle()
                .fill(Color.black.opacity(0.28))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close Now Playing")
            .zIndex(0)

            VisionNowPlayingPanel(
              scrollToQueue: navigation.nowPlayingPresentation.scrollToQueue,
              onDismiss: { navigation.nowPlayingPresentation.dismiss() }
            )
            .zIndex(1)
          }
          .ignoresSafeArea()
          .transition(.opacity)
        }
      }
      .background {
        Button("Search") { navigation.requestSearchFocus() }
          .keyboardShortcut("f", modifiers: .command)
          .opacity(0)
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
      }
      .onChange(of: appModel.activeBrowseSessionKey) { _, _ in
        // A SharePlay rating key is scoped to the exact backend/account that resolved it.
        watchTogetherCoordinator.leave()
      }
      .sheet(
        isPresented: Binding(
          get: { watchTogetherCoordinator.joinPrompt != nil },
          set: {
            if !$0, watchTogetherCoordinator.joinPrompt != nil {
              watchTogetherCoordinator.declineIncoming()
            }
          }
        )
      ) {
        WatchTogetherJoinView()
      }
  }

  private var tabs: some View {
    TabView(selection: $navigation.selection) {
      Tab("Home", systemImage: "house", value: AppDestination.home) {
        visionBrowseStack(.home, path: $navigation.homePath, origin: .home) {
          HomeView(catalogRepository: runtime.libraryCatalogRepository)
        }
      }
      Tab("Libraries", systemImage: "rectangle.stack", value: AppDestination.libraries) {
        visionBrowseStack(.libraries, path: $navigation.librariesPath, origin: .libraries) {
          LibrariesView(catalogRepository: runtime.libraryCatalogRepository)
        }
      }
      Tab("Search", systemImage: "magnifyingglass", value: AppDestination.search) {
        visionBrowseStack(.search, path: $navigation.searchPath, origin: .search) {
          SearchView(
            focusRequest: navigation.searchFocusRequest,
            onClearSearch: navigation.exitSearch,
            catalogRepository: runtime.libraryCatalogRepository)
        }
      }
      Tab("Music", systemImage: "music.note", value: AppDestination.music) {
        BrowseNavigationStack(
          path: $navigation.musicPath,
          sessionKey: appModel.activeBrowseSessionKey,
          onPush: { navigation.push($0, on: .music) }
        ) {
          MusicLibraryView(catalogRepository: runtime.libraryCatalogRepository)
        }
      }
      Tab("Offline", systemImage: "arrow.down.circle", value: AppDestination.offline) {
        NavigationStack {
          OfflineLibraryView(
            manager: downloadManager,
            focusedRatingKey: $navigation.offlineReturnRatingKey)
        }
      }
      Tab("Settings", systemImage: "gearshape", value: AppDestination.settings) {
        NavigationStack {
          SettingsView(
            authManager: authManager,
            catalogRepository: runtime.libraryCatalogRepository)
        }
      }
    }
    // A scene ornament, rather than safeAreaInset, is the native visionOS transport surface.
    .ornament(attachmentAnchor: .scene(.bottom)) {
      MiniPlayerBar(presentation: $navigation.nowPlayingPresentation)
    }
  }

  private func visionBrowseStack<Content: View>(
    _ destination: AppDestination,
    path: Binding<NavigationPath>,
    origin: CinemaTab,
    @ViewBuilder content: () -> Content
  ) -> some View {
    BrowseNavigationStack(
      path: path,
      sessionKey: appModel.activeBrowseSessionKey,
      onPush: { navigation.push($0, on: destination) },
      content: content
    )
    .environment(\.cinemaOriginTab, origin)
  }
}
