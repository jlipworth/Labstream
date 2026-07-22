import PMSKit
import SwiftUI

enum MobileSettingsPresentationAction: Equatable {
  case unchanged
  case presentSheet(selecting: AppDestination)
}

enum MobileSettingsPresentationPolicy {
  static func action(selection: AppDestination, isCompact: Bool)
    -> MobileSettingsPresentationAction
  {
    guard isCompact, selection == .settings else { return .unchanged }
    return .presentSheet(selecting: .home)
  }
}

/// Adaptive iPhone/iPad shell. The system owns compact tabs, the iPad sidebar, and Search's
/// dedicated role; the shared coordinator owns only destination transitions and paths.
struct PlatformRootShell: View {
  let runtime: AppRuntime
  @Bindable var navigation: RootNavigationCoordinator

  @Environment(\.horizontalSizeClass) private var horizontalSizeClass
  @State private var showsSettingsSheet = false

  private var appModel: AppModel { runtime.appModel }
  private var authManager: AuthManager { runtime.authManager }
  private var downloadManager: DownloadManager { runtime.downloadManager }
  private var musicPlayer: MusicPlayerController { runtime.musicPlayer }

  var body: some View {
    TabView(selection: $navigation.selection) {
      ForEach(mobileTabs, id: \.self) { destination in
        Tab(
          destination.title,
          systemImage: destination.systemImage,
          value: destination
        ) {
          destinationContent(destination)
        }
      }
      Tab(
        AppDestination.search.title,
        systemImage: AppDestination.search.systemImage,
        value: AppDestination.search,
        role: .search
      ) {
        destinationContent(.search)
      }
    }
    .tabViewStyle(.sidebarAdaptable)
    .tabBarMinimizeBehavior(.onScrollDown)
    .tabViewBottomAccessory(isEnabled: musicPlayer.current != nil) {
      MiniPlayerBar(presentation: $navigation.nowPlayingPresentation)
    }
    .sheet(isPresented: $showsSettingsSheet) {
      NavigationStack {
        SettingsView(
          authManager: authManager,
          catalogRepository: runtime.libraryCatalogRepository
        )
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { showsSettingsSheet = false }
          }
        }
      }
    }
    .onChange(of: navigation.selection) { _, destination in
      if destination == .search {
        navigation.requestSearchFocus(selectsSearch: false)
      }
    }
    // A compact-width transition can remove the selected Settings tab. Atomically return to
    // Home and show the compact Settings sheet so selection is never stranded.
    .onChange(of: usesCompactTabSet) { _, isCompact in
      switch MobileSettingsPresentationPolicy.action(
        selection: navigation.selection, isCompact: isCompact)
      {
      case .unchanged:
        break
      case .presentSheet(let selection):
        navigation.selection = selection
        showsSettingsSheet = true
      }
    }
    .background {
      Button("Search") { navigation.requestSearchFocus() }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }

  private var usesCompactTabSet: Bool { horizontalSizeClass == .compact }

  private var mobileTabs: [AppDestination] {
    AppDestination.allCases.filter { destination in
      if destination == .search { return false }
      if destination == .settings, usesCompactTabSet { return false }
      return true
    }
  }

  @ToolbarContentBuilder
  private var compactSettingsToolbar: some ToolbarContent {
    if usesCompactTabSet {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          showsSettingsSheet = true
        } label: {
          Label("Settings", systemImage: "gearshape")
        }
      }
    }
  }

  @ViewBuilder
  private func destinationContent(_ destination: AppDestination) -> some View {
    switch destination {
    case .home:
      browseStack(.home, path: $navigation.homePath) {
        HomeView(catalogRepository: runtime.libraryCatalogRepository)
          .toolbar { compactSettingsToolbar }
      }
    case .libraries:
      browseStack(.libraries, path: $navigation.librariesPath) {
        LibrariesView(catalogRepository: runtime.libraryCatalogRepository)
          .toolbar { compactSettingsToolbar }
      }
    case .search:
      browseStack(.search, path: $navigation.searchPath) {
        SearchView(
          focusRequest: navigation.searchFocusRequest,
          onClearSearch: navigation.exitSearch,
          catalogRepository: runtime.libraryCatalogRepository)
      }
    case .music:
      browseStack(.music, path: $navigation.musicPath) {
        MusicLibraryView(catalogRepository: runtime.libraryCatalogRepository)
          .toolbar { compactSettingsToolbar }
      }
    case .offline:
      NavigationStack {
        OfflineLibraryView(manager: downloadManager)
          .toolbar { compactSettingsToolbar }
      }
    case .settings:
      NavigationStack {
        SettingsView(
          authManager: authManager,
          catalogRepository: runtime.libraryCatalogRepository)
      }
    }
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
