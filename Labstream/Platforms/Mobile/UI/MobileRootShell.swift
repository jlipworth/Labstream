import PMSKit
import SwiftUI

enum MobileSettingsPresentationAction: Equatable {
  case unchanged
  case presentSheet(selecting: AppDestination)
  /// Regular width brings the Settings tab back: close the compact sheet and select the tab.
  case dismissSheet(selecting: AppDestination)
}

enum MobileSettingsPresentationPolicy {
  /// Keeps Settings reachable across a horizontal size-class change (iPad multitasking resize,
  /// iPhone Duo fold/unfold). Compact width has no Settings tab, so a selected Settings tab moves
  /// into the sheet; regular width restores the tab, so an open sheet hands back to it.
  static func action(
    selection: AppDestination, isCompact: Bool, isSettingsSheetPresented: Bool = false
  ) -> MobileSettingsPresentationAction {
    if isCompact {
      guard selection == .settings else { return .unchanged }
      return .presentSheet(selecting: .home)
    }
    guard isSettingsSheetPresented else { return .unchanged }
    return .dismissSheet(selecting: .settings)
  }
}

/// Adaptive iPhone/iPad shell. The system owns the tab bar (a bottom tab bar, the iPadOS
/// sidebar or tab bar, and on the iOS 27.1 SDK the vertical bar on a foldable iPhone's
/// trailing edge) and Search's dedicated role; the shared coordinator owns only destination
/// transitions and paths. `.sidebarAdaptable` gives a sidebar only on iPadOS in regular
/// width; with the phone idiom it stays a tab bar even in regular width (an unfolded iPhone
/// Duo). Tab-set and Settings decisions key on the horizontal size class, never the idiom.
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
    // Home and show the compact Settings sheet so selection is never stranded. The reverse
    // transition (an iPad window widening, an iPhone Duo unfolding) restores the tab, so an
    // open compact sheet hands off to it instead of floating over a tab set that has Settings.
    .onChange(of: usesCompactTabSet) { _, isCompact in
      switch MobileSettingsPresentationPolicy.action(
        selection: navigation.selection, isCompact: isCompact,
        isSettingsSheetPresented: showsSettingsSheet)
      {
      case .unchanged:
        break
      case .presentSheet(let selection):
        navigation.selection = selection
        showsSettingsSheet = true
      case .dismissSheet(let selection):
        showsSettingsSheet = false
        navigation.selection = selection
      }
    }
    .background {
      Button("Search") { navigation.focusSearchFromCommand() }
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
