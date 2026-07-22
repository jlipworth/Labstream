import PMSKit
import SwiftUI

/// Native single-window Mac source-list shell and retained full-window player host.
struct PlatformRootShell: View {
  let runtime: AppRuntime
  @Bindable var navigation: RootNavigationCoordinator

  @State private var macPlayerPresenter = MacPlayerPresentationStore()
  @State private var macSidebarModel = MacSidebarModel()
  @State private var macSelection: MacSidebarDestination = .home
  @State private var macLoadedServerIdentity: String?
  @State private var macSelectedMusicLibraryID: String?
  @State private var macSearchText = ""
  @State private var macSearchPresented = false
  @State private var macConfirmingSignOut = false
  @State private var macWasCompactWidth = false
  @State private var macColumnVisibility: NavigationSplitViewVisibility = .all
  @State private var macColumnVisibilityBeforePlayer: NavigationSplitViewVisibility = .all

  private var appModel: AppModel { runtime.appModel }
  private var authManager: AuthManager { runtime.authManager }
  private var downloadManager: DownloadManager { runtime.downloadManager }
  private var musicPlayer: MusicPlayerController { runtime.musicPlayer }

  var body: some View {
    ZStack {
      macNavigationSplitView
        .safeAreaInset(edge: .bottom) {
          if musicPlayer.current != nil, !macPlayerPresenter.isPresented {
            MiniPlayerBar(presentation: $navigation.nowPlayingPresentation)
              .padding(.horizontal, 16)
              .padding(.vertical, 8)
              .background(.regularMaterial)
          }
        }
        .searchable(
          text: $macSearchText,
          isPresented: $macSearchPresented,
          placement: .toolbar,
          prompt: "Movies, shows, music…")
        .accessibilityIdentifier("performance.mac.search-field")

      if let presentation = macPlayerPresenter.presentation {
        presentation.content
          .id(presentation.contentID)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .background(Color.black)
          .ignoresSafeArea()
          .transition(.opacity.combined(with: .scale(scale: 0.998)))
          .zIndex(10)
      }
    }
    .background {
      GeometryReader { geometry in
        MacWindowToolbarVisibilityController(hidesToolbar: macPlayerPresenter.isPresented)
          .frame(width: 0, height: 0)
          .onAppear { updateMacWindowWidth(geometry.size.width) }
          .onChange(of: geometry.size.width) { _, width in
            updateMacWindowWidth(width)
          }
      }
    }
    .environment(\.macPlayerPresentationStore, macPlayerPresenter)
    .animation(.easeInOut(duration: 0.16), value: macPlayerPresenter.isPresented)
    .onExitCommand {
      if macSearchPresented {
        dismissMacSearch()
      } else {
        macNavigateBack()
      }
    }
    .onChange(of: macSearchText) { oldValue, newValue in
      if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        macSearchPresented = true
      } else if !oldValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        dismissMacSearch()
      }
    }
    .onChange(of: macSearchPresented) { _, isPresented in
      if !isPresented {
        macSearchText = ""
        navigation.searchPath = NavigationPath()
      }
    }
    .onChange(of: macSelection) { oldSelection, newSelection in
      macSidebarSelectionChanged(from: oldSelection, to: newSelection)
    }
    .onChange(of: macPlayerPresenter.isPresented) { _, isPresented in
      updateMacNavigationChrome(forPlayerPresentation: isPresented)
    }
    .task(id: appModel.activeBrowseSessionKey) {
      await reloadMacSidebar()
    }
    .onReceive(
      NotificationCenter.default.publisher(for: LibraryVisibilityStore.didChangeNotification)
    ) { notification in
      guard
        let backendKey = notification.userInfo?[
          LibraryVisibilityStore.didChangeBackendKeyUserInfoKey] as? String,
        backendKey == appModel.libraryVisibilityBackendKey
      else { return }
      Task { await reloadMacSidebar() }
    }
    .onChange(of: MacMainWindowController.shared.pendingCommands) { _, requests in
      guard let request = requests.first else { return }
      handleMacWindowCommand(request)
    }
    .task {
      if let request = MacMainWindowController.shared.pendingCommands.first {
        handleMacWindowCommand(request)
      }
    }
    .onAppear {
      let presenter = macPlayerPresenter
      navigation.willNavigateToResolvedSystemEntry = { [weak presenter] in
        presenter?.dismissForResolvedSystemEntry()
      }
    }
    .onDisappear {
      navigation.willNavigateToResolvedSystemEntry = nil
    }
    .onChange(of: navigation.selection) { _, destination in
      switch destination {
      case .home:
        macSelection = .home
      case .libraries:
        if case .library = macSelection {} else { macSelection = .home }
      case .search:
        focusSearch()
      case .music:
        if case .music = macSelection {} else { macSelection = .music(.home) }
      case .offline:
        macSelection = .offline
      case .settings:
        break
      }
    }
    .confirmationDialog(
      "Sign out of \(appModel.activeBackend.displayName)?",
      isPresented: $macConfirmingSignOut,
      titleVisibility: .visible
    ) {
      Button("Sign Out", role: .destructive) { authManager.signOut() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(macSignOutConfirmationMessage)
    }
    .sheet(
      item: Binding(
        get: { macSidebarModel.visibilityPrompt },
        set: { _ in }
      )
    ) { prompt in
      LibraryVisibilityPickerSheet(prompt: prompt) { hiddenIDs in
        macSidebarModel.applyVisibility(hiddenIDs, backendKey: prompt.backendKey)
        Task { await reloadMacSidebar() }
      } onCancel: {
        macSidebarModel.dismissVisibilityPrompt(backendKey: prompt.backendKey)
      }
    }
  }

  private func handleMacWindowCommand(_ request: MacMainWindowController.CommandRequest) {
    switch request.command {
    case .navigateBack:
      macNavigateBack()
    case .focusSearch:
      focusSearch()
    case .selectOffline:
      if !macPlayerPresenter.isPresented {
        macSelection = .offline
      }
    case .requestSignOut:
      if appModel.isAuthenticated {
        macConfirmingSignOut = true
      }
    }
    MacMainWindowController.shared.consume(request)
  }

  private var macNavigationSplitView: some View {
    NavigationSplitView(columnVisibility: $macColumnVisibility) {
      macSidebar
    } detail: {
      macDetail
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationSplitViewStyle(.balanced)
  }

  private var macSidebar: some View {
    List(selection: $macSelection) {
      macSidebarRow(.home, title: "Home", systemImage: "house")
        .accessibilityIdentifier("performance.mac.sidebar.home")

      if !macSidebarModel.catalog.libraries.isEmpty {
        Section("Libraries") {
          ForEach(macSidebarModel.catalog.libraries) { library in
            macLibrarySidebarRow(library)
          }
        }
      }

      if !macSidebarModel.catalog.musicDestinations.isEmpty {
        Section("Music") {
          ForEach(macSidebarModel.catalog.musicDestinations) { pivot in
            macMusicSidebarRow(pivot)
          }
        }
      }

      Section { macOfflineSidebarRow }
    }
    .navigationTitle("Labstream")
    .frame(minWidth: 220)
    .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 280)
  }

  @ViewBuilder
  private var macDetail: some View {
    if macSearchPresented {
      BrowseNavigationStack(
        path: $navigation.searchPath,
        sessionKey: appModel.activeBrowseSessionKey,
        onPush: { navigation.push($0, on: .search) }
      ) {
        SearchView(
          query: $macSearchText,
          onClearSearch: dismissMacSearch,
          catalogRepository: runtime.libraryCatalogRepository
        )
        .navigationTitle("Search")
      }
    } else {
      macTabContent(for: macSelection)
    }
  }

  private func updateMacNavigationChrome(forPlayerPresentation isPresented: Bool) {
    if isPresented {
      if macColumnVisibility != .detailOnly {
        macColumnVisibilityBeforePlayer = macColumnVisibility
      }
      macColumnVisibility = .detailOnly
    } else {
      macColumnVisibility = macColumnVisibilityBeforePlayer
    }
  }

  private func updateMacWindowWidth(_ width: CGFloat) {
    // A 230-point source list plus a roughly 670-point useful browse/detail surface is the
    // smallest combination that remained legible in the #232 native pass. Below that, let the
    // detail own the available width while preserving NavigationSplitView's native toggle.
    let isCompact = width < 900
    guard isCompact != macWasCompactWidth else { return }
    macWasCompactWidth = isCompact
    guard !macPlayerPresenter.isPresented else { return }
    macColumnVisibility = isCompact ? .detailOnly : .all
  }

  private func reloadMacSidebar() async {
    let previousIdentity = macLoadedServerIdentity
    await macSidebarModel.load(
      appModel: appModel,
      catalogRepository: runtime.libraryCatalogRepository)
    guard !Task.isCancelled else { return }

    let catalog = macSidebarModel.catalog
    let currentRoute = macSelection.routeID(serverIdentity: previousIdentity)
    let candidate: MacSidebarRouteID?
    if previousIdentity != catalog.serverIdentity {
      candidate = MacSidebarSelectionStore().route(for: catalog.serverIdentity)
    } else {
      candidate = currentRoute
    }
    let restored = MacSidebarDestinationPolicy.restoredRoute(candidate, in: catalog)
    macLoadedServerIdentity = catalog.serverIdentity
    macSelection = MacSidebarDestination.make(route: restored)

    let visibleMusicIDs = Set(catalog.musicLibraries.map(\.id))
    if let selected = macSelectedMusicLibraryID, visibleMusicIDs.contains(selected) {
      // Preserve Music Home's explicit context for child destinations.
    } else {
      macSelectedMusicLibraryID = catalog.musicLibraries.first?.id
    }
    MacSidebarSelectionStore().save(restored, for: catalog.serverIdentity)
  }

  private func macSidebarSelectionChanged(
    from oldSelection: MacSidebarDestination,
    to newSelection: MacSidebarDestination
  ) {
    dismissMacSearch()
    if case .library(let oldID) = oldSelection,
      case .library(let newID) = newSelection,
      oldID != newID
    {
      navigation.librariesPath = NavigationPath()
    } else if case .library = newSelection, oldSelection != newSelection {
      navigation.librariesPath = NavigationPath()
    }

    switch newSelection {
    case .home: navigation.selection = .home
    case .library: navigation.selection = .libraries
    case .music: navigation.selection = .music
    case .offline: navigation.selection = .offline
    }

    let route = newSelection.routeID(serverIdentity: macSidebarModel.catalog.serverIdentity)
    guard macSidebarModel.catalog.validRouteIDs.contains(route) else { return }
    MacSidebarSelectionStore().save(route, for: macSidebarModel.catalog.serverIdentity)
  }

  private func dismissMacSearch() {
    macSearchPresented = false
    macSearchText = ""
    navigation.searchPath = NavigationPath()
  }

  private var canMacNavigateBack: Bool {
    guard !macPlayerPresenter.isPresented else { return false }
    guard !macSearchPresented else { return true }
    switch macSelection {
    case .home:
      return !navigation.homePath.isEmpty
    case .library:
      return !navigation.librariesPath.isEmpty
    case .music:
      return !navigation.musicPath.isEmpty
    case .offline:
      return false
    }
  }

  private func macNavigateBack() {
    if macSearchPresented {
      dismissMacSearch()
      return
    }
    guard canMacNavigateBack else { return }
    switch macSelection {
    case .home:
      navigation.homePath.removeLast()
    case .library:
      navigation.librariesPath.removeLast()
    case .music:
      navigation.musicPath.removeLast()
    case .offline:
      break
    }
  }

  private func macSidebarRow(
    _ destination: MacSidebarDestination,
    title: String,
    systemImage: String
  ) -> some View {
    Label(title, systemImage: systemImage)
      .tag(destination)
  }

  private func macLibrarySidebarRow(_ library: MacSidebarLibraryDescriptor) -> some View {
    macSidebarRow(.library(library.id), title: library.title, systemImage: library.kind.systemImage)
      .accessibilityLabel(library.accessibilityTitle)
      .accessibilityIdentifier("performance.mac.sidebar.library")
  }

  private func macMusicSidebarRow(_ pivot: MusicPivot) -> some View {
    let symbol =
      switch pivot {
      case .home: "music.note.house"
      case .artists: "music.microphone"
      case .albums: "square.stack"
      case .playlists: "music.note.list"
      }
    return macSidebarRow(
      .music(pivot), title: pivot == .home ? "Music Home" : pivot.rawValue,
      systemImage: symbol)
  }

  private var macOfflineSidebarRow: some View {
    HStack {
      Label("Offline", systemImage: "arrow.down.circle")
      Spacer()
      if let percent = downloadManager.offlineLibrarySnapshot.activeTransferPercentage {
        Text("\(percent)%")
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityLabel("\(percent) percent downloaded")
      }
    }
    .tag(MacSidebarDestination.offline)
  }

  private var macSignOutConfirmationMessage: String {
    switch appModel.activeBackend {
    case .plex:
      "Signing back in requires authorizing this device with plex.tv again."
    case .jellyfin:
      "Signing back in requires connecting to your Jellyfin server again."
    case .emby:
      "Signing back in requires connecting to your Emby server again."
    }
  }

  @ViewBuilder
  private func macTabContent(for destination: MacSidebarDestination) -> some View {
    switch destination {
    case .home:
      BrowseNavigationStack(
        path: $navigation.homePath,
        sessionKey: appModel.activeBrowseSessionKey,
        onPush: { navigation.push($0, on: .home) }
      ) {
        HomeView(catalogRepository: runtime.libraryCatalogRepository)
          .navigationTitle("Home")
      }
    case .library(let id):
      if let source = macSidebarModel.librarySources[id] {
        BrowseNavigationStack(
          path: $navigation.librariesPath,
          sessionKey: appModel.activeBrowseSessionKey,
          onPush: { navigation.push($0, on: .libraries) }
        ) {
          LibraryGridView(source: source)
            .navigationTitle(source.title)
            .navigationDestination(for: MediaItem.self) { item in
              DetailView(item: item, originBackend: appModel.activeBackend)
            }
            .navigationDestination(for: LibraryGridSource.self) { pushedSource in
              LibraryGridView(source: pushedSource)
            }
        }
      } else {
        HomeView(catalogRepository: runtime.libraryCatalogRepository)
      }
    case .music(let pivot):
      BrowseNavigationStack(
        path: $navigation.musicPath,
        sessionKey: appModel.activeBrowseSessionKey,
        onPush: { navigation.push($0, on: .music) }
      ) {
        MusicLibraryView(
          macPivot: pivot,
          selectedLibraryID: $macSelectedMusicLibraryID,
          allowedLibraryIDs: Set(macSidebarModel.catalog.musicLibraries.map(\.id)),
          catalogRepository: runtime.libraryCatalogRepository
        )
        .navigationTitle(pivot == .home ? "Music" : pivot.rawValue)
      }
    case .offline:
      NavigationStack {
        OfflineLibraryView(manager: downloadManager)
          .navigationTitle("Offline")
      }
    }
  }

  private func focusSearch() {
    guard !macPlayerPresenter.isPresented else { return }
    macSearchPresented = true
    navigation.requestSearchFocus(selectsSearch: false)
  }
}
