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
    let attempt: MediaBrowserHomeRailAttempt
    let pendingRailKeys: [MediaBrowserHomeRailPlan.Key]
    let failedRailKeys: [MediaBrowserHomeRailPlan.Key]
    let hasFailedKeyRetryRemaining: Bool

    var isComplete: Bool { pendingRailKeys.isEmpty }
    var isDegraded: Bool { !failedRailKeys.isEmpty }
    var isTerminal: Bool {
        isComplete && (!isDegraded || !hasFailedKeyRetryRemaining)
    }
    var isAuthoritative: Bool { isComplete && !isDegraded }
}

enum MediaBrowserHomePublicationPolicy {
    static func shouldPin(_ content: MediaBrowserHomeContent) -> Bool {
        content.isAuthoritative
    }

    /// Keep the skeleton while a partial snapshot has nothing useful to render. The first visible
    /// successful rail transitions to content. Empty/degraded content transitions only when the
    /// one failed-key retry is exhausted, so a held retry cannot look like terminal failure.
    static func shouldShowLoadedState(_ content: MediaBrowserHomeContent) -> Bool {
        !content.rails.isEmpty || content.isTerminal
    }
}

/// Shared Jellyfin/Emby Home provider. Keeps Plex Home native while removing the duplicate
/// MediaBrowser branches from `HomeView` and the method-for-method `homeRails` service helpers.
@MainActor
struct MediaBrowserHomeProvider {
    typealias SnapshotHandler = @MainActor (MediaBrowserHomeContent) -> Void

    /// One ceiling covers global and per-library requests together. Plan order determines which
    /// work enters the initial window; completion order only determines snapshot timing.
    static let maximumConcurrentRailRequests = 4

    let appModel: AppModel
    /// Snapshot the lane at task creation. `HomeView` cancels/replaces its task when the browse
    /// identity changes, but an already-running async child can still resume briefly after the
    /// user switches Emby/Jellyfin -> Plex. Reading `appModel.activeBackend` at that point used to
    /// route the stale MediaBrowser task into a Plex precondition failure.
    let backend: MediaBackendKind
    private let browser: any MediaBrowserHomeBrowsing
    private let catalogRepository: LibraryCatalogRepository
    private let catalogRequest: LibraryCatalogRequest?
    private let sessionIdentity: String
    private let visibilityBackendKey: String?
    private let visibilityLegacyBackendKeys: [String]
    private let visibilityStore: LibraryVisibilityStore

    init?(appModel: AppModel, catalogRepository: LibraryCatalogRepository) {
        self.appModel = appModel
        backend = appModel.activeBackend
        self.catalogRepository = catalogRepository
        catalogRequest = try? catalogRepository.request(appModel: appModel)
        sessionIdentity = appModel.activeBrowseSessionKey
        visibilityBackendKey = appModel.libraryVisibilityBackendKey
        visibilityLegacyBackendKeys = appModel.libraryVisibilityLegacyBackendKeys
        visibilityStore = LibraryVisibilityStore()

        switch appModel.activeBackend {
        case .emby:
            browser = EmbyBrowseService(appModel: appModel)
        case .jellyfin:
            browser = JellyfinBrowseService(appModel: appModel)
        case .plex:
            return nil
        }
    }

    /// Deterministic execution seam. Production still uses the initializer above; tests can bind
    /// an exact catalog authority and controlled browser without touching URL loading.
    init(appModel: AppModel,
         browser: any MediaBrowserHomeBrowsing,
         catalogRepository: LibraryCatalogRepository,
         catalogRequest: LibraryCatalogRequest,
         visibilityStore: LibraryVisibilityStore) {
        precondition(appModel.activeBackend.isMediaBrowser)
        self.appModel = appModel
        backend = appModel.activeBackend
        self.browser = browser
        self.catalogRepository = catalogRepository
        self.catalogRequest = catalogRequest
        sessionIdentity = appModel.activeBrowseSessionKey
        visibilityBackendKey = appModel.libraryVisibilityBackendKey
        visibilityLegacyBackendKeys = appModel.libraryVisibilityLegacyBackendKeys
        self.visibilityStore = visibilityStore
    }

    func loadHome(forceRefresh: Bool = false,
                  onSnapshot: SnapshotHandler? = nil) async throws -> MediaBrowserHomeContent {
        // Use the captured backend keys rather than mutable active-backend state. A stale task may
        // finish after a switch, but HomeView's generation/identity guard will discard its result.
        guard let catalogRequest else {
            throw LibraryCatalogRepositoryError.noAuthenticatedSession
        }
        let snapshot = try await catalogRepository.catalog(for: catalogRequest,
                                                           forceRefresh: forceRefresh)
        guard snapshot.isCurrent(in: appModel) else {
            throw CancellationError()
        }
        let allLibraries = snapshot.descriptors.map {
            MediaBrowserHomeLibraryLink(id: $0.sourceID,
                                        title: $0.title,
                                        collectionType: $0.sourceKind)
        }
        visibilityStore.migrateLegacyBackendKeys(visibilityLegacyBackendKeys,
                                                 toBackendKey: visibilityBackendKey)
        let hidden = visibilityStore.hiddenIDs(forBackendKey: visibilityBackendKey)
        let libraries = LibraryVisibility.visible(allLibraries, hiddenIDs: hidden) { $0.id }
        let load = try await homeRails(for: libraries,
                                       authority: snapshot.authority) { railLoad in
            onSnapshot?(content(libraries: libraries, load: railLoad))
        }

        guard snapshot.isCurrent(in: appModel),
              !Task.isCancelled else { throw CancellationError() }

        return content(libraries: libraries, load: load)
    }

    private func homeRails(for libraries: [MediaBrowserHomeLibraryLink],
                           authority: BrowseSessionAuthority,
                           onSnapshot: @MainActor (MediaBrowserHomeRailLoad) -> Void) async throws
        -> MediaBrowserHomeRailLoad {
        let plan = MediaBrowserHomeRailPlan(libraries: libraries,
                                            backend: backend,
                                            sessionIdentity: sessionIdentity)
        let initialAttempt = MediaBrowserHomeRailAttempt(authority: authority)
        var reducer = MediaBrowserHomeRailReducer(plan: plan, attempt: initialAttempt)
        try await run(plan.work,
                      authority: authority,
                      attempt: initialAttempt,
                      reducer: &reducer,
                      onSnapshot: onSnapshot)

        // One automatic recovery pass retries only keys that failed. Successful and empty-success
        // rails remain in the reducer, so recovery cannot refetch or temporarily remove them.
        let retryAttempt = MediaBrowserHomeRailAttempt(authority: authority)
        let retryKeys = reducer.beginFailedKeyRetry(attempt: retryAttempt)
        if !retryKeys.isEmpty {
            let retrySet = Set(retryKeys)
            let retryWork = plan.work.filter { retrySet.contains($0.key) }
            // Publish the phase transition before retry work starts. With no retained visible rail,
            // Home stays (or returns) to its skeleton until the recovery pass actually settles.
            try Task.checkCancellation()
            guard let current = appModel.activeAuthenticatedBrowseSession,
                  current.backend == backend,
                  current.authority == authority else { throw CancellationError() }
            onSnapshot(reducer.load)
            try await run(retryWork,
                          authority: authority,
                          attempt: retryAttempt,
                          reducer: &reducer,
                          onSnapshot: onSnapshot)
        }

        let load = reducer.load
        if load.isDegraded {
            NSLog("[#93] %@ homeRails degraded after failed-key retry: %d of up to %d rails returned; will not pin loaded identity",
                  backend.displayName,
                  load.rails.count,
                  plan.entries.count)
        }

        return load
    }

    private func run(_ work: [MediaBrowserHomeRailPlan.Work],
                     authority: BrowseSessionAuthority,
                     attempt: MediaBrowserHomeRailAttempt,
                     reducer: inout MediaBrowserHomeRailReducer,
                     onSnapshot: @MainActor (MediaBrowserHomeRailLoad) -> Void) async throws {
        let capturedBrowser = browser
        var nextIndex = 0

        try Task.checkCancellation()
        guard let current = appModel.activeAuthenticatedBrowseSession,
              current.backend == backend,
              current.authority == authority else { throw CancellationError() }
        try await withThrowingTaskGroup(of: RailCompletion.self) { group in
            func submit(_ index: Int) {
                let item = work[index]
                group.addTask {
                    do {
                        return RailCompletion(
                            key: item.key,
                            result: .success(try await Self.execute(item.request,
                                                                    browser: capturedBrowser))
                        )
                    } catch {
                        return RailCompletion(key: item.key, result: .failure(error))
                    }
                }
            }

            for _ in 0..<min(Self.maximumConcurrentRailRequests, work.count) {
                submit(nextIndex)
                nextIndex += 1
            }

            while let completion = try await group.next() {
                try Task.checkCancellation()
                guard let current = appModel.activeAuthenticatedBrowseSession,
                      current.backend == backend,
                      current.authority == authority else {
                    group.cancelAll()
                    throw CancellationError()
                }
                guard reducer.record(completion.result,
                                     for: completion.key,
                                     attempt: attempt) else { continue }

                if nextIndex < work.count {
                    submit(nextIndex)
                    nextIndex += 1
                }
                onSnapshot(reducer.load)
            }
        }
    }

    private func content(libraries: [MediaBrowserHomeLibraryLink],
                         load: MediaBrowserHomeRailLoad) -> MediaBrowserHomeContent {
        MediaBrowserHomeContent(libraries: libraries,
                                rails: load.rails,
                                attempt: load.attempt,
                                pendingRailKeys: load.pendingKeys,
                                failedRailKeys: load.failedKeys,
                                hasFailedKeyRetryRemaining: load.hasFailedKeyRetryRemaining)
    }

    nonisolated private static func execute(
        _ request: MediaBrowserHomeRailPlan.Request,
        browser: any MediaBrowserHomeBrowsing
    ) async throws -> [MediaItem] {
        switch request {
        case .resume(let limit):
            return try await browser.homeResumeItems(limit: limit)
        case .nextUp(let limit):
            return try await browser.homeNextUp(limit: limit)
        case .latest(let parentID, let itemTypes, let limit):
            return try await browser.homeLatestItems(parentId: parentID,
                                                     includeItemTypes: itemTypes,
                                                     limit: limit)
        }
    }

    private struct RailCompletion: Sendable {
        let key: MediaBrowserHomeRailPlan.Key
        let result: Result<[MediaItem], Error>
    }

    nonisolated static func latestItemTypes(for library: MediaBrowserHomeLibraryLink) -> String {
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
/// `Sendable` allows the existential to ride the bounded task-group children in `homeRails` while
/// the concrete service entry points remain main-actor-isolated.
@MainActor
protocol MediaBrowserHomeBrowsing: Sendable {
    func homeResumeItems(limit: Int) async throws -> [MediaItem]
    func homeNextUp(limit: Int) async throws -> [MediaItem]
    func homeLatestItems(parentId: String, includeItemTypes: String, limit: Int) async throws -> [MediaItem]
}

extension JellyfinBrowseService: MediaBrowserHomeBrowsing {
    func homeResumeItems(limit: Int) async throws -> [MediaItem] {
        try await resumeItems(limit: limit)
    }

    func homeNextUp(limit: Int) async throws -> [MediaItem] {
        try await nextUp(limit: limit)
    }

    func homeLatestItems(parentId: String, includeItemTypes: String, limit: Int) async throws -> [MediaItem] {
        try await latestItems(parentId: parentId, includeItemTypes: includeItemTypes, limit: limit,
                              metadataProfile: MediaBrowserMetadataFieldProfiles.home)
    }
}

extension EmbyBrowseService: MediaBrowserHomeBrowsing {
    func homeResumeItems(limit: Int) async throws -> [MediaItem] {
        try await resumeItems(limit: limit)
    }

    func homeNextUp(limit: Int) async throws -> [MediaItem] {
        try await nextUp(limit: limit)
    }

    func homeLatestItems(parentId: String, includeItemTypes: String, limit: Int) async throws -> [MediaItem] {
        try await latestItems(parentId: parentId, includeItemTypes: includeItemTypes, limit: limit,
                              metadataProfile: MediaBrowserMetadataFieldProfiles.home)
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
