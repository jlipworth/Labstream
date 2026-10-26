import PMSKit
import SwiftUI

enum MobileSettingsPresentationAction: Equatable {
  case unchanged
  case presentSheet(selecting: AppDestination)
  /// Regular width brings the Settings tab back: close the compact sheet and select the tab.
  case dismissSheet(selecting: AppDestination)
}

/// Settings navigation shared by the compact sheet (one form) and the regular-width tab (two
/// columns), so a size-class change (iPhone Duo fold/unfold, iPad resize) keeps the user's place
/// (design spec global rule 9): the tab's selected category is where the form scrolls to, and
/// the section the form was showing becomes the selected category.
struct MobileSettingsNavigationState: Equatable {
  var path: [SettingsRoute] = []
  var category: SettingsCategory?

  /// Opening the sheet from the toolbar is a fresh visit: start at the Settings root.
  mutating func beginFreshVisit() {
    path = []
    category = nil
  }

  /// The form hands over to the two-column layout: a pushed screen selects the category that owns
  /// it, otherwise the section the form was showing.
  mutating func takeOverFromForm(showing formCategory: SettingsCategory) {
    category = path.last?.category ?? formCategory
  }
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
  @Environment(\.labstreamVerticalBarEdge) private var verticalBarEdge
  @State private var showsSettingsSheet = false
  @State private var settingsNavigation = MobileSettingsNavigationState()
  @State private var settingsFormAnchors = SettingsFormAnchorTracker()

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
    .tabBarMinimizeBehavior(
      MobileShellLayoutPolicy.minimizesTabBarOnScroll(verticalBarEdge: verticalBarEdge)
        ? .onScrollDown : .automatic)
    // With horizontal bars the system places the accessory above the bottom tab capsule. Beside
    // a vertical bar each tab hosts the bar as a bottom inset instead (`miniPlayerInset`).
    .tabViewBottomAccessory(
      isEnabled: musicPlayer.current != nil && miniPlayerPlacement == .tabBottomAccessory
    ) {
      MiniPlayerBar(presentation: $navigation.nowPlayingPresentation)
    }
    .nowPlayingSheet(presentation: $navigation.nowPlayingPresentation)
    .sheet(isPresented: $showsSettingsSheet) {
      NavigationStack(path: $settingsNavigation.path) {
        SettingsView(
          authManager: authManager,
          catalogRepository: runtime.libraryCatalogRepository,
          restoreCategory: settingsNavigation.category)
          .mobileSettingsSheetChrome { showsSettingsSheet = false }
      }
      .environment(\.settingsFormAnchorTracker, settingsFormAnchors)
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
        // Same visit: the tab's path carries into the sheet, which scrolls to its category.
        settingsFormAnchors.reset()
        navigation.selection = selection
        showsSettingsSheet = true
      case .dismissSheet(let selection):
        // Same visit: the sheet's path carries into the tab, selecting the section it showed.
        settingsNavigation.takeOverFromForm(
          showing: settingsFormAnchors.committed ?? SettingsCategoryPolicy.defaultCategory)
        showsSettingsSheet = false
        navigation.selection = selection
      }
    }
    #if DEBUG
    .task { applyDebugCaptureRoute() }
    #endif
    .background {
      Button("Search") { navigation.focusSearchFromCommand() }
        .keyboardShortcut("f", modifiers: .command)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
  }

  private var usesCompactTabSet: Bool { horizontalSizeClass == .compact }

  #if DEBUG
  /// Browse-fixture capture routes (`DebugUITestLaunchConfiguration`), applied once at launch.
  private func applyDebugCaptureRoute() {
    guard DebugUITestLaunchConfiguration.usesBrowseFixture else { return }
    if let raw = DebugUITestLaunchConfiguration.initialSettingsCategory {
      settingsNavigation.category = SettingsCategory(rawValue: raw)
    }
    if let raw = DebugUITestLaunchConfiguration.initialTab,
      let destination = AppDestination.allCases.first(where: { "\($0)" == raw })
    {
      if destination == .settings, usesCompactTabSet {
        // Compact width has no Settings tab: the toolbar gear's sheet is the Settings surface.
        showsSettingsSheet = true
      } else {
        navigation.selection = destination
      }
    }
    if DebugUITestLaunchConfiguration.opensFirstLibrary, navigation.librariesPath.isEmpty {
      navigation.selection = .libraries
      navigation.librariesPath.append(
        LibraryRootItem.Destination.plex(PlexSection(key: "1", title: "Movies", type: "movie")))
    }
    if let key = DebugUITestLaunchConfiguration.initialOpenItemKey, navigation.homePath.isEmpty,
      let item = DebugUIFixtureCatalog.item(ratingKey: key, backend: appModel.activeBackend)
    {
      navigation.selection = .home
      navigation.homePath.append(item)
    }
  }
  #endif

  private var miniPlayerPlacement: MobileShellLayoutPolicy.MiniPlayerPlacement {
    MobileShellLayoutPolicy.miniPlayerPlacement(verticalBarEdge: verticalBarEdge)
  }

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
          settingsNavigation.beginFreshVisit()
          settingsFormAnchors.reset()
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
      .miniPlayerInset(placement: miniPlayerPlacement,
                       presentation: $navigation.nowPlayingPresentation)
    case .settings:
      // The Settings tab exists only in regular width: two columns, like iPad Settings.
      MobileSettingsSplitView(
        selection: $settingsNavigation.category,
        path: $settingsNavigation.path,
        includesDownloads: true
      ) { category in
        SettingsView(
          authManager: authManager,
          catalogRepository: runtime.libraryCatalogRepository,
          category: category)
          .id(category)
      }
      .miniPlayerInset(placement: miniPlayerPlacement,
                       presentation: $navigation.nowPlayingPresentation)
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
    .miniPlayerInset(placement: miniPlayerPlacement,
                     presentation: $navigation.nowPlayingPresentation)
  }
}

extension View {
  /// Beside a vertical bar, hosts the mini player as a bottom safe-area inset of a tab: it is
  /// centred in the content region (the tab's safe area already excludes the column), never sits
  /// under the column, and every scroll viewport in the tab ends above it (Resolved decision 4).
  /// With horizontal bars the shell's `tabViewBottomAccessory` hosts it instead.
  fileprivate func miniPlayerInset(
    placement: MobileShellLayoutPolicy.MiniPlayerPlacement,
    presentation: Binding<NowPlayingPresentationState>
  ) -> some View {
    modifier(MiniPlayerInsetModifier(placement: placement, presentation: presentation))
  }
}

private struct MiniPlayerInsetModifier: ViewModifier {
  let placement: MobileShellLayoutPolicy.MiniPlayerPlacement
  @Binding var presentation: NowPlayingPresentationState

  @Environment(MusicPlayerController.self) private var musicPlayer
  @Environment(\.labstreamCompactWidth) private var compactWidth

  func body(content: Content) -> some View {
    content.safeAreaInset(edge: .bottom, spacing: 0) {
      if placement == .bottomSafeAreaInset, musicPlayer.current != nil,
        !presentation.isPresented
      {
        MiniPlayerBar(presentation: $presentation, hostsPlatter: true)
          .frame(maxWidth: 560)
          .padding(.horizontal, DS.pagePadding(compact: compactWidth))
          .padding(.bottom, DS.Space.sm)
      }
    }
  }
}
