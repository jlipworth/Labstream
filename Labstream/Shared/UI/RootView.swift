import PMSKit
import SwiftUI

/// Common authenticated composition wrapped around the four native platform shells.
///
/// `RootNavigationCoordinator` owns transitions shared across products. `PlatformRootShell` is a
/// target-exclusive type supplied by each `Labstream/Platforms/*` root, so platform presentation
/// stays independently reviewable without runtime feature flags or a universal layout.
struct RootView: View {
  let runtime: AppRuntime

  @State private var navigation = RootNavigationCoordinator()

  private var appModel: AppModel { runtime.appModel }
  private var musicPlayer: MusicPlayerController { runtime.musicPlayer }

  var body: some View {
    PlatformRootShell(runtime: runtime, navigation: navigation)
      .environment(\.metadataRepository, runtime.metadataRepository)
      // Browse-session switch: discard only online navigation. Offline is deliberately
      // cross-backend because every DownloadRecord retains its own backend authority.
      .onChange(of: appModel.activeBrowseSessionKey) { _, _ in
        navigation.resetForBrowseSessionChange()
        musicPlayer.stopIfBrowseSessionChanged()
      }
      .onChange(of: navigation.selection) { _, destination in
        navigation.selectionDidChange(to: destination)
      }
      // Now Playing's artist/album requests originate outside the destination stack.
      .onChange(of: musicPlayer.navigationRequest) { _, item in
        guard let item else { return }
        musicPlayer.navigationRequest = nil
        navigation.navigateToMusic(item)
      }
      .onChange(of: SystemEntryRouter.shared.pending) { _, route in
        guard let route else { return }
        handleSystemEntry(route)
      }
      #if os(visionOS)
        .onChange(of: SystemEntryRouter.shared.offlinePending) { _, route in
          guard let route else { return }
          navigation.consumeOfflineReturn(route)
        }
      #endif
      .task {
        // System entries can arrive while restore/login UI is still mounted. Consume the
        // process-lifetime pending value when this authenticated shell appears.
        if let route = SystemEntryRouter.shared.pending {
          handleSystemEntry(route)
        }
        #if os(visionOS)
          if let route = SystemEntryRouter.shared.offlinePending {
            navigation.consumeOfflineReturn(route)
          }
        #endif
      }
      .environment(appModel)
      #if !os(tvOS)
        .environment(runtime.downloadManager)
      #endif
      .environment(musicPlayer)
      .environment(\.artworkPipeline, runtime.artworkPipeline)
      .environment(\.artworkShimmerClock, runtime.artworkShimmerClock)
  }

  private func handleSystemEntry(_ route: SystemEntryRouter.Route) {
    #if os(visionOS)
      let destination = route.originTab.flatMap(AppDestination.init) ?? .home
    #else
      let destination = AppDestination.home
    #endif
    navigation.handleSystemEntry(route, target: destination, runtime: runtime)
  }
}
