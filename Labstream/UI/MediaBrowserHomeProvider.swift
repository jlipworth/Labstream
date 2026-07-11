import Foundation
import PMSKit

/// Backend-neutral library descriptor for the Jellyfin/Emby Home screen.
///
/// Plex Home still uses native `/hubs`; MediaBrowser Home is library-scoped and can share the
/// visibility filtering, "Continue Watching" / "Next Up", and per-library latest-item rails.
struct MediaBrowserHomeLibraryLink: Identifiable, Hashable {
    let id: String
    let title: String
    let collectionType: String?
}

/// Backend-neutral rail descriptor for Jellyfin/Emby Home.
struct MediaBrowserHomeRail: Identifiable, Hashable {
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

    private var browser: any MediaBrowserHomeBrowsing {
        switch appModel.activeBackend {
        case .emby:
            return EmbyBrowseService(appModel: appModel)
        case .jellyfin:
            return JellyfinBrowseService(appModel: appModel)
        case .plex:
            preconditionFailure("MediaBrowserHomeProvider does not handle Plex Home")
        }
    }

    func loadHome() async throws -> MediaBrowserHomeContent {
        let allLibraries = try await browser.homeLibraryLinks()
        let visibilityStore = LibraryVisibilityStore()
        appModel.migrateLibraryVisibilityKeysIfNeeded(store: visibilityStore)
        let hidden = visibilityStore.hiddenIDs(forBackendKey: appModel.libraryVisibilityBackendKey)
        let libraries = LibraryVisibility.visible(allLibraries, hiddenIDs: hidden) { $0.id }
        let load = try await homeRails(for: libraries)

        return MediaBrowserHomeContent(libraries: libraries,
                                       rails: load.rails,
                                       isDegraded: load.isDegraded)
    }

    private func homeRails(for libraries: [MediaBrowserHomeLibraryLink]) async throws -> HomeRailsLoad<MediaBrowserHomeRail> {
        var rails: [MediaBrowserHomeRail] = []
        let sessionIdentity = appModel.activeBrowseSessionKey
        let backend = appModel.activeBackend
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

        for library in libraries.prefix(8) {
            let items = await tracker.attempt {
                try await browser.homeLatestItems(parentId: library.id,
                                                  includeItemTypes: MediaBrowserHomeProvider.latestItemTypes(for: library),
                                                  limit: 20)
            } ?? []
            if !items.isEmpty {
                rails.append(MediaBrowserHomeRail(id: "latest-\(library.id)",
                                                  title: "Recently Added \(library.title)",
                                                  items: items,
                                                  destination: RailViewAllDestination(title: "Recently Added \(library.title)", backend: backend, sessionIdentity: sessionIdentity, query: .mediaBrowserRecentlyAdded(parentID: library.id, itemTypes: MediaBrowserHomeProvider.latestItemTypes(for: library)))))
            }
        }

        if tracker.isDegraded {
            NSLog("[#93] %@ homeRails degraded: %d of up to %d rails returned; will not pin loaded identity",
                  appModel.activeBackend.displayName,
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
