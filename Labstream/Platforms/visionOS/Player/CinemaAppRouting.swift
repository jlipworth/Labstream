import PMSKit

/// App-layer composition for the visionOS Cinema handoff.
///
/// `CinemaExitRouting` owns the backend-neutral decision. This adapter deliberately owns only
/// the final app actions so they can be tested without mounting SwiftUI or an ImmersiveSpace.
enum CinemaAppRouting {
    static func onlineOrigin(for tab: CinemaTab?) -> CinemaOrigin {
        tab.map(CinemaOrigin.onlineTab) ?? .systemEntry
    }

    @MainActor
    static func dispatch(
        _ destination: CinemaExitDestination,
        returnItem: MediaItem?,
        openOnlineTabItem: (MediaItem, Bool, CinemaTab) -> Void,
        openSystemEntryItem: (MediaItem, Bool) -> Void,
        openOfflineDownload: (String) -> Void
    ) {
        switch destination {
        case .offlineDownload(let ratingKey):
            openOfflineDownload(ratingKey)
        case .onlineTabItem(let tab, let autoPlay):
            guard let returnItem else { return }
            openOnlineTabItem(returnItem, autoPlay, tab)
        case .systemEntryItem(let autoPlay):
            guard let returnItem else { return }
            openSystemEntryItem(returnItem, autoPlay)
        case .none:
            break
        }
    }
}
