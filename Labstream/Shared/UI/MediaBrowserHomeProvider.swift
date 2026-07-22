import Foundation
import PMSKit

/// Backend-neutral library descriptor for the Jellyfin/Emby Home screen.
///
/// Plex Home still uses native `/hubs`; MediaBrowser Home is library-scoped and can share the
/// visibility filtering, "Continue Watching" / "Next Up", and per-library latest-item rails.
struct MediaBrowserHomeLibraryLink: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let collectionType: String?
}

/// Backend-neutral rail descriptor for Jellyfin/Emby Home.
struct MediaBrowserHomeRail: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [MediaItem]
    let destination: RailViewAllDestination?
}

struct MediaBrowserHomeContent {
    let libraries: [MediaBrowserHomeLibraryLink]
    let rails: [MediaBrowserHomeRail]
    let isDegraded: Bool
}

/// Shared Jellyfin/Emby Home provider. Keeps Plex Home native while removing the duplicate
/// MediaBrowser branches from `HomeView` and the method-for-method `homeRails` service helpers.
@MainActor
struct MediaBrowserHomeProvider {
    let appModel: AppModel
    /// Snapshot the lane at task creation. `HomeView` cancels/replaces its task when the browse
    /// identity changes, but an already-running async child can still resume briefly after the
    /// user switches Emby/Jellyfin -> Plex. Reading `appModel.activeBackend` at that point used to
    /// route the stale MediaBrowser task into a Plex precondition failure.
    let backend: MediaBackendKind
    private let browser: any MediaBrowserHomeBrowsing
    private let sessionIdentity: String
    private let visibilityBackendKey: String?
    private let visibilityLegacyBackendKeys: [String]

    init?(appModel: AppModel) {
        self.appModel = appModel
        backend = appModel.activeBackend
        sessionIdentity = appModel.activeBrowseSessionKey
        visibilityBackendKey = appModel.libraryVisibilityBackendKey
        visibilityLegacyBackendKeys = appModel.libraryVisibilityLegacyBackendKeys

        switch appModel.activeBackend {
        case .emby:
            browser = EmbyBrowseService(appModel: appModel)
        case .jellyfin:
            browser = JellyfinBrowseService(appModel: appModel)
        case .plex:
            return nil
        }
    }

    func loadHome() async throws -> MediaBrowserHomeContent {
        // Use the captured backend keys rather than mutable active-backend state. A stale task may
        // finish after a switch, but HomeView's generation/identity guard will discard its result.
        let allLibraries = try await browser.homeLibraryLinks()
        let visibilityStore = LibraryVisibilityStore()
        visibilityStore.migrateLegacyBackendKeys(visibilityLegacyBackendKeys,
                                                 toBackendKey: visibilityBackendKey)
        let hidden = visibilityStore.hiddenIDs(forBackendKey: visibilityBackendKey)
        let libraries = LibraryVisibility.visible(allLibraries, hiddenIDs: hidden) { $0.id }
        let load = try await homeRails(for: libraries)

        return MediaBrowserHomeContent(libraries: libraries,
                                       rails: load.rails,
                                       isDegraded: load.isDegraded)
    }

    private func homeRails(for libraries: [MediaBrowserHomeLibraryLink]) async throws -> HomeRailsLoad<MediaBrowserHomeRail> {
        var rails: [MediaBrowserHomeRail] = []
        // Track per-rail errors so a partial MediaBrowser Home is displayed but not pinned as
        // authoritative; a pop-back / later `.task` can recover missing rails (#93).
        var tracker = HomeRailsLoadTracker()

        // These rails are independent server requests. Launch the global rails together, then
        // fold them back in the existing fixed display order.
        async let continueWatchingResult = HomeRailsLoadTracker.resultOf {
            try await browser.homeResumeItems(limit: 20)
        }
        async let nextUpResult = HomeRailsLoadTracker.resultOf {
            try await browser.homeNextUp(limit: 20)
        }

        if let continueWatching = tracker.record(await continueWatchingResult), !continueWatching.isEmpty {
            rails.append(MediaBrowserHomeRail(id: "continue-watching",
                                              title: "Continue Watching",
                                              items: continueWatching,
                                              destination: RailViewAllDestination(title: "Continue Watching", backend: backend, sessionIdentity: sessionIdentity, query: .mediaBrowserResume(parentID: nil))))
        }

        if let nextUpItems = tracker.record(await nextUpResult), !nextUpItems.isEmpty {
            rails.append(MediaBrowserHomeRail(id: "next-up",
                                              title: "Next Up",
                                              items: nextUpItems,
                                              destination: RailViewAllDestination(title: "Next Up", backend: backend, sessionIdentity: sessionIdentity, query: .mediaBrowserNextUp(parentID: nil))))
        }

        // A server may expose eight eligible libraries. Keep their requests concurrent without
        // allowing Home to create an unbounded burst against the server or URLSession.
        let latestLibraries = Array(libraries.prefix(8))
        let latestResults = try await BoundedAsyncMap.results(
            latestLibraries,
            maximumConcurrentTasks: 4
        ) { [browser] library in
            try await browser.homeLatestItems(
                parentId: library.id,
                includeItemTypes: MediaBrowserHomeProvider.latestItemTypes(for: library),
                limit: 20
            )
        }

        // Completion order is intentionally irrelevant: preserve the server's library order in
        // the rendered rails while retaining successful rails when a sibling request fails.
        for (library, result) in zip(latestLibraries, latestResults) {
            let items = tracker.record(result) ?? []
            if !items.isEmpty {
                rails.append(MediaBrowserHomeRail(id: "latest-\(library.id)",
                                                  title: "Recently Added \(library.title)",
                                                  items: items,
                                                  destination: RailViewAllDestination(title: "Recently Added \(library.title)", backend: backend, sessionIdentity: sessionIdentity, query: .mediaBrowserRecentlyAdded(parentID: library.id, itemTypes: MediaBrowserHomeProvider.latestItemTypes(for: library)))))
            }
        }

        if tracker.isDegraded {
            NSLog("[#93] %@ homeRails degraded: %d of up to %d rails returned; will not pin loaded identity",
                  backend.displayName,
                  rails.count,
                  libraries.prefix(8).count + 2)
        }

        return HomeRailsLoad(rails: rails, isDegraded: tracker.isDegraded)
    }

    static func latestItemTypes(for library: MediaBrowserHomeLibraryLink) -> String {
        switch library.collectionType?.lowercased() {
        case "movies":
            return "Movie"
        case "tvshows":
            return "Episode"
        case "homevideos", "livetv":
            return "Video"
        default:
            return "Movie,Episode,Video"
        }
    }
}

/// The slice of a MediaBrowser browse service needed by Home. Both concrete services already
/// expose these shapes; the conformances below map them onto the common seam.
///
/// `Sendable` allows the existential to ride the `async let` calls in `homeRails` while the
/// concrete services remain main-actor-isolated.
@MainActor
protocol MediaBrowserHomeBrowsing: Sendable {
    func homeLibraryLinks() async throws -> [MediaBrowserHomeLibraryLink]
    func homeResumeItems(limit: Int) async throws -> [MediaItem]
    func homeNextUp(limit: Int) async throws -> [MediaItem]
    func homeLatestItems(parentId: String, includeItemTypes: String, limit: Int) async throws -> [MediaItem]
}

extension JellyfinBrowseService: MediaBrowserHomeBrowsing {
    func homeLibraryLinks() async throws -> [MediaBrowserHomeLibraryLink] {
        try await userViewLinks().map {
            MediaBrowserHomeLibraryLink(id: $0.id, title: $0.title, collectionType: $0.collectionType)
        }
    }

    func homeResumeItems(limit: Int) async throws -> [MediaItem] {
        try await resumeItems(limit: limit)
    }

    func homeNextUp(limit: Int) async throws -> [MediaItem] {
        try await nextUp(limit: limit)
    }

    func homeLatestItems(parentId: String, includeItemTypes: String, limit: Int) async throws -> [MediaItem] {
        try await latestItems(parentId: parentId, includeItemTypes: includeItemTypes, limit: limit)
    }
}

extension EmbyBrowseService: MediaBrowserHomeBrowsing {
    func homeLibraryLinks() async throws -> [MediaBrowserHomeLibraryLink] {
        try await userViewLinks().map {
            MediaBrowserHomeLibraryLink(id: $0.id, title: $0.title, collectionType: $0.collectionType)
        }
    }

    func homeResumeItems(limit: Int) async throws -> [MediaItem] {
        try await resumeItems(limit: limit)
    }

    func homeNextUp(limit: Int) async throws -> [MediaItem] {
        try await nextUp(limit: limit)
    }

    func homeLatestItems(parentId: String, includeItemTypes: String, limit: Int) async throws -> [MediaItem] {
        try await latestItems(parentId: parentId, includeItemTypes: includeItemTypes, limit: limit)
    }
}

extension MediaBackendKind {
    var isMediaBrowser: Bool {
        switch self {
        case .jellyfin, .emby: return true
        case .plex: return false
        }
    }
}
