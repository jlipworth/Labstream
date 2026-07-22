import PMSKit
import SwiftUI

/// Focus-driven Apple TV shell. Offline is absent by product contract.
struct PlatformRootShell: View {
  let runtime: AppRuntime
  @Bindable var navigation: RootNavigationCoordinator

  private var appModel: AppModel { runtime.appModel }
  private var authManager: AuthManager { runtime.authManager }
  private var musicPlayer: MusicPlayerController { runtime.musicPlayer }

  var body: some View {
    TabView(selection: $navigation.selection) {
      Tab("Home", systemImage: "house", value: AppDestination.home) {
        browseStack(.home, path: $navigation.homePath) {
          HomeView(catalogRepository: runtime.libraryCatalogRepository)
        }
      }
      Tab("Libraries", systemImage: "rectangle.stack", value: AppDestination.libraries) {
        browseStack(.libraries, path: $navigation.librariesPath) {
          LibrariesView(catalogRepository: runtime.libraryCatalogRepository)
        }
      }
      Tab("Search", systemImage: "magnifyingglass", value: AppDestination.search) {
        browseStack(.search, path: $navigation.searchPath) {
          // Search is a persistent TV tab, so Clear resets in place.
          SearchView(
            focusRequest: navigation.searchFocusRequest,
            catalogRepository: runtime.libraryCatalogRepository)
        }
      }
      Tab("Music", systemImage: "music.note", value: AppDestination.music) {
        browseStack(.music, path: $navigation.musicPath) {
          MusicLibraryView(catalogRepository: runtime.libraryCatalogRepository)
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
    .safeAreaInset(edge: .bottom) {
      if musicPlayer.current != nil {
        MiniPlayerBar(presentation: $navigation.nowPlayingPresentation)
      }
    }
    // At a lifted-stack root the handler must be nil so Settings can pop itself and the
    // system can move focus to the tab bar / leave the app normally.
    .onExitCommand(
      perform: navigation.canNavigateBack(in: navigation.selection)
        ? {
          navigation.navigateBack(in: navigation.selection)
        } : nil)
  }

  private func browseStack<Content: View>(
    _ destination: AppDestination,
    path: Binding<NavigationPath>,
    @ViewBuilder content: () -> Content
  ) -> some View {
    BrowseNavigationStack(
      path: path,
      sessionKey: appModel.activeBrowseSessionKey,
      onPush: { navigation.push($0, on: destination) },
      content: content)
  }
}
