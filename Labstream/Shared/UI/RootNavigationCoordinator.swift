import PMSKit
import SwiftUI

/// Shared destinations and online navigation state used by the four native app shells.
///
/// Platform views still decide how these destinations are presented (tabs, a source list, or an
/// adaptive sidebar). This coordinator owns only the transitions that must remain identical across
/// those shells: session-scoped paths, Search return behavior, system-entry routing, and Cinema's
/// offline return handoff.
enum AppDestination: Hashable, CaseIterable {
  case home, libraries, search, music, offline, settings

  var title: String {
    switch self {
    case .home: "Home"
    case .libraries: "Libraries"
    case .search: "Search"
    case .music: "Music"
    case .offline: "Offline"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .home: "house"
    case .libraries: "rectangle.stack"
    case .search: "magnifyingglass"
    case .music: "music.note"
    case .offline: "arrow.down.circle"
    case .settings: "gearshape"
    }
  }

  #if os(visionOS)
    init?(_ cinemaTab: CinemaTab) {
      switch cinemaTab {
      case .home: self = .home
      case .libraries: self = .libraries
      case .search: self = .search
      }
    }
  #endif
}

@MainActor
@Observable
final class RootNavigationCoordinator {
  var selection: AppDestination = .home
  private(set) var lastNonSearchSelection: AppDestination = .home

  var homePath = NavigationPath()
  var librariesPath = NavigationPath()
  var searchPath = NavigationPath()
  var musicPath = NavigationPath()

  var nowPlayingPresentation = NowPlayingPresentationState()
  var offlineReturnRatingKey: String?
  private(set) var searchFocusRequest = 0

  @ObservationIgnored private var systemEntryTask: Task<Void, Never>?
  @ObservationIgnored private var systemEntryGeneration = 0
  @ObservationIgnored var willNavigateToResolvedSystemEntry: (@MainActor () -> Void)?

  func selectionDidChange(to destination: AppDestination) {
    if destination != .search {
      lastNonSearchSelection = destination
    }
  }

  func requestSearchFocus(selectsSearch: Bool = true) {
    if selectsSearch {
      selection = .search
    }
    searchFocusRequest += 1
  }

  func exitSearch() {
    searchPath = NavigationPath()
    selection = lastNonSearchSelection == .search ? .home : lastNonSearchSelection
  }

  func resetForBrowseSessionChange() {
    cancelSystemEntryTask()
    homePath = NavigationPath()
    librariesPath = NavigationPath()
    searchPath = NavigationPath()
    musicPath = NavigationPath()
    // Offline downloads are cross-backend. In particular, do not erase a pending Cinema
    // return merely because the online browse authority changed while the window was absent.
  }

  func resetPath(for destination: AppDestination) {
    switch destination {
    case .home: homePath = NavigationPath()
    case .libraries: librariesPath = NavigationPath()
    case .search: searchPath = NavigationPath()
    case .music: musicPath = NavigationPath()
    case .offline, .settings: break
    }
  }

  func push(_ item: MediaItem, on destination: AppDestination) {
    switch destination {
    case .home: homePath.append(item)
    case .libraries: librariesPath.append(item)
    case .search: searchPath.append(item)
    case .music: musicPath.append(item)
    case .offline, .settings: homePath.append(item)
    }
  }

  func canNavigateBack(in destination: AppDestination) -> Bool {
    switch destination {
    case .home: !homePath.isEmpty
    case .libraries: !librariesPath.isEmpty
    case .search: !searchPath.isEmpty
    case .music: !musicPath.isEmpty
    case .offline, .settings: false
    }
  }

  func navigateBack(in destination: AppDestination) {
    switch destination {
    case .home where !homePath.isEmpty: homePath.removeLast()
    case .libraries where !librariesPath.isEmpty: librariesPath.removeLast()
    case .search where !searchPath.isEmpty: searchPath.removeLast()
    case .music where !musicPath.isEmpty: musicPath.removeLast()
    default: break
    }
  }

  func navigateToMusic(_ item: MediaItem) {
    selection = .music
    // The destination stack mounts after the selection transaction. Preserve the proven
    // next-turn handoff so its Back button corresponds to content the user actually saw.
    Task { @MainActor [weak self] in
      self?.musicPath.append(item)
    }
  }

  #if os(visionOS)
    func consumeOfflineReturn(_ route: SystemEntryRouter.OfflineReturn) {
      SystemEntryRouter.shared.offlinePending = nil
      offlineReturnRatingKey = route.ratingKey
      selection = .offline
    }
  #endif

  /// Resolve and perform one App Intent, Spotlight, or Cinema-return route. The async work is
  /// fenced to both this coordinator generation and the exact browse-session authority.
  func handleSystemEntry(
    _ route: SystemEntryRouter.Route,
    target destination: AppDestination,
    runtime: AppRuntime
  ) {
    let router = SystemEntryRouter.shared
    router.pending = nil
    systemEntryTask?.cancel()
    systemEntryGeneration += 1
    let generation = systemEntryGeneration
    let browseSessionKey = runtime.appModel.activeBrowseSessionKey
    selection = destination
    resetPath(for: destination)

    systemEntryTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        if generation == self.systemEntryGeneration {
          self.systemEntryTask = nil
        }
      }

      @MainActor
      func isCurrentRoute() -> Bool {
        if Task.isCancelled { return false }
        if generation != self.systemEntryGeneration { return false }
        return runtime.appModel.activeBrowseSessionKey == browseSessionKey
      }

      guard isCurrentRoute() else { return }
      var item: MediaItem?
      var authoritativeSnapshot: MetadataSnapshot?
      switch route.target {
      case .item(let given):
        item = given
      case .routeKey(let routeKey):
        let routeBackend = routeKey.backend
        guard runtime.appModel.activeBackend == routeBackend,
          let session = runtime.appModel.backendSession(
            for: routeBackend)
        else {
          return
        }
        if let namespace = routeKey.serverNamespace,
          namespace != BackendScopedMediaID.serverNamespace(session.baseURL)
        {
          return
        }
        let result = await DetailMetadataLoader.load(
          ratingKey: routeKey.ratingKey,
          backend: routeBackend,
          appModel: runtime.appModel,
          repository: runtime.metadataRepository,
          policy: .authoritative)
        item = result.item
        authoritativeSnapshot = result.snapshot
        guard isCurrentRoute() else { return }
      }
      guard var item else { return }

      var autoPlay = route.autoPlay
      if autoPlay, item.isContainer {
        let leaf = await self.resolveSystemEntryLeaf(
          from: item,
          appModel: runtime.appModel)
        guard isCurrentRoute() else { return }
        if let leaf {
          item = leaf
          authoritativeSnapshot = nil
        } else {
          autoPlay = false
        }
      }

      // The Mac retained-player hook is installed by MacRootShell. It deliberately runs only
      // after target resolution succeeds, so a stale/deleted route never interrupts playback.
      self.willNavigateToResolvedSystemEntry?()

      // A Cinema exit can recreate the main window and its NavigationStack in the same
      // transaction. Yield once so the selected stack exists before appending its detail.
      await Task.yield()
      guard isCurrentRoute() else { return }
      if autoPlay, item.isPlayableLeaf, !item.isMusic {
        router.requestAutoPlay(
          forRatingKey: item.ratingKey,
          snapshot: authoritativeSnapshot)
      }
      self.push(item, on: destination)
    }
  }

  private func resolveSystemEntryLeaf(
    from item: MediaItem,
    appModel: AppModel
  ) async -> MediaItem? {
    if item.isPlayableLeaf { return item }
    switch item.kind {
    case .season:
      let episodes =
        (try? await systemEntryChildren(
          for: item.ratingKey,
          appModel: appModel)) ?? []
      return firstSystemEntryLeaf(in: episodes)
    case .show:
      let seasons =
        (try? await systemEntryChildren(
          for: item.ratingKey,
          appModel: appModel)) ?? []
      for season in seasons {
        let episodes =
          (try? await systemEntryChildren(
            for: season.ratingKey,
            appModel: appModel)) ?? []
        if let first = firstSystemEntryLeaf(in: episodes) { return first }
      }
      return nil
    default:
      return nil
    }
  }

  private func systemEntryChildren(
    for ratingKey: String,
    appModel: AppModel
  ) async throws -> [MediaItem] {
    switch appModel.activeBackend {
    case .plex:
      guard let service = try? PlexBrowseService(appModel: appModel) else {
        throw URLError(.userAuthenticationRequired)
      }
      return try await service.children(ratingKey: ratingKey)
    case .jellyfin:
      return try await JellyfinBrowseService(appModel: appModel)
        .items(parentId: ratingKey, recursive: false)
    case .emby:
      return try await EmbyBrowseService(appModel: appModel)
        .items(parentId: ratingKey, recursive: false)
    }
  }

  private func firstSystemEntryLeaf(in items: [MediaItem]) -> MediaItem? {
    items
      .filter(\.isPlayableLeaf)
      .sorted { lhs, rhs in
        let l = (lhs.parentIndex ?? Int.max, lhs.index ?? Int.max)
        let r = (rhs.parentIndex ?? Int.max, rhs.index ?? Int.max)
        return l < r
      }
      .first
  }

  private func cancelSystemEntryTask() {
    systemEntryTask?.cancel()
    systemEntryTask = nil
    systemEntryGeneration += 1
  }
}
