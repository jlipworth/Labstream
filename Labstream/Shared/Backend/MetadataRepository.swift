import Foundation
import PMSKit

/// Whether an item metadata caller may use the repository's bounded display reuse policy.
enum MetadataReadPolicy: Sendable {
    case display
    /// Native read required, except that the exact current in-flight native read may be joined.
    case authoritative
}

enum MetadataDeliveryProvenance: Sendable, Equatable {
    case nativeRead
    case freshDisplayReuse
    case staleWhileRevalidate
}

/// Credential-safe evidence describing how a metadata value reached its caller.
struct MetadataProvenance: Sendable, Equatable {
    let delivery: MetadataDeliveryProvenance
    let watchedStatePatched: Bool

    /// Only an unmodified native response may supply playback-selection metadata. Cache-painted,
    /// stale, or locally patched values remain presentation-only even under the same authority.
    var mayAuthorizeActions: Bool {
        delivery == .nativeRead && !watchedStatePatched
    }
}

/// One authority-fenced metadata value. Credentials and server identity deliberately remain in
/// the private execution request and never enter repository keys, provenance, or diagnostics.
struct MetadataSnapshot: Sendable {
    let backend: MediaBackendKind
    let authority: BrowseSessionAuthority
    /// Opaque repository-native source revision. This is process-local and contains no server,
    /// account, request, or credential material.
    let sourceRevision: UInt64
    let item: MediaItem
    let provenance: MetadataProvenance

    @MainActor
    func isCurrent(in appModel: AppModel) -> Bool {
        appModel.authenticatedBrowseSession(for: backend)?.authority == authority
    }

    @MainActor
    func mayAuthorizeAction(in appModel: AppModel,
                            backend expectedBackend: MediaBackendKind,
                            itemID expectedItemID: String) -> Bool {
        backend == expectedBackend
            && item.ratingKey == expectedItemID
            && provenance.mayAuthorizeActions
            && isCurrent(in: appModel)
    }

    /// Mirror an already-accepted watched mutation into a mounted Detail without upgrading that
    /// locally patched value into playback authority.
    func patchingWatchedState(played: Bool) -> MetadataSnapshot {
        MetadataSnapshot(backend: backend,
                         authority: authority,
                         sourceRevision: sourceRevision,
                         item: MetadataItemCopy.withPlayed(item, played: played),
                         provenance: MetadataProvenance(delivery: provenance.delivery,
                                                        watchedStatePatched: true))
    }
}

enum MetadataRepositoryError: Error, LocalizedError, Equatable {
    case noAuthenticatedSession
    case backendMismatch
    case authorityMismatch
    case authorityExpired

    var errorDescription: String? {
        switch self {
        case .noAuthenticatedSession: return "No server selected."
        case .backendMismatch:
            return "The metadata request does not match the authenticated backend."
        case .authorityMismatch:
            return "The metadata loader does not match the authenticated session."
        case .authorityExpired:
            return "The authenticated metadata session is no longer current."
        }
    }
}

/// Exact immutable authority plus the native backend read captured in one MainActor turn.
struct MetadataRequest {
    fileprivate let context: AuthenticatedBrowseSessionContext
    fileprivate let itemID: String
    fileprivate let loaderBackend: MediaBackendKind
    fileprivate let loaderAuthority: BrowseSessionAuthority
    fileprivate let load: @MainActor @Sendable () async throws -> MediaItem
    fileprivate let isCurrent: @MainActor @Sendable () -> Bool
}

/// App-lifetime item metadata execution boundary.
///
/// Display reads may reuse a fresh value or briefly paint a stale exact-authority value while one
/// repository-owned refresh runs. Authoritative reads ignore cached values and always perform (or
/// join) a native read. No stale/background value crosses an authority or authorizes an action.
@MainActor
final class MetadataRepository {
    typealias Now = @MainActor @Sendable () -> UInt64
    typealias BeforeNativeDelivery = @MainActor @Sendable () async -> Void

    static let defaultFreshDisplayTTLNanoseconds: UInt64 = 10_000_000_000
    static let defaultStaleDisplayTTLNanoseconds: UInt64 = 60_000_000_000

    private struct Key: Hashable {
        let backend: MediaBackendKind
        let authority: BrowseSessionAuthority
        let itemID: String
    }

    private struct CachedValue {
        let item: MediaItem
        let sourceRevision: UInt64
        let freshUntil: UInt64
        let staleUntil: UInt64
        let watchedStatePatched: Bool
    }

    private struct LoadedMetadata: Sendable {
        let item: MediaItem
        let sourceRevision: UInt64
        let watchedStatePatched: Bool
        /// Highest local watched mutation folded into `item`. A mutation can land after a
        /// native task publishes but before one of its joined waiters resumes, so delivery must
        /// reconcile against the current patch revision as well as publication ordering.
        let appliedWatchedPatchRevision: UInt64
    }

    private struct InFlight {
        let generation: UInt64
        let task: Task<LoadedMetadata, Error>
    }

    private struct WatchedPatch {
        let revision: UInt64
        let played: Bool
    }

    private let freshDisplayTTLNanoseconds: UInt64
    private let staleDisplayTTLNanoseconds: UInt64
    private let now: Now
    private let beforeNativeDelivery: BeforeNativeDelivery?
    private var values: [Key: CachedValue] = [:]
    private var flights: [Key: InFlight] = [:]
    private var watchedPatches: [Key: WatchedPatch] = [:]
    private var currentAuthorityByBackend: [MediaBackendKind: BrowseSessionAuthority] = [:]
    private var nextGeneration: UInt64 = 0
    private var nextWatchedPatchRevision: UInt64 = 0

    init(freshDisplayTTLNanoseconds: UInt64 = MetadataRepository.defaultFreshDisplayTTLNanoseconds,
         staleDisplayTTLNanoseconds: UInt64 = MetadataRepository.defaultStaleDisplayTTLNanoseconds,
         now: @escaping Now = { DispatchTime.now().uptimeNanoseconds },
         beforeNativeDelivery: BeforeNativeDelivery? = nil) {
        precondition(staleDisplayTTLNanoseconds >= freshDisplayTTLNanoseconds,
                     "The stale display deadline must not precede the fresh deadline")
        self.freshDisplayTTLNanoseconds = freshDisplayTTLNanoseconds
        self.staleDisplayTTLNanoseconds = staleDisplayTTLNanoseconds
        self.now = now
        self.beforeNativeDelivery = beforeNativeDelivery
    }

    func request(appModel: AppModel,
                 backend: MediaBackendKind,
                 itemID: String) throws -> MetadataRequest {
        guard let context = appModel.authenticatedBrowseSession(for: backend) else {
            throw MetadataRepositoryError.noAuthenticatedSession
        }

        let load: @MainActor @Sendable () async throws -> MediaItem
        switch backend {
        case .plex:
            let service = try PlexBrowseService(session: context.session,
                                                identity: context.clientIdentity,
                                                client: appModel.client)
            load = { try await service.metadata(ratingKey: itemID) }
        case .jellyfin:
            let service = JellyfinBrowseService(appModel: appModel)
            load = {
                try await service.metadata(itemId: itemID,
                                           session: context.session,
                                           identity: context.clientIdentity)
            }
        case .emby:
            let service = EmbyBrowseService(appModel: appModel)
            load = {
                try await service.metadata(itemId: itemID,
                                           session: context.session,
                                           identity: context.clientIdentity)
            }
        }

        return request(context: context, itemID: itemID, load: load) { [weak appModel] in
            appModel?.authenticatedBrowseSession(for: backend)?.authority == context.authority
        }
    }

    /// Injectable request seam for deterministic repository and integration contracts.
    func request(context: AuthenticatedBrowseSessionContext,
                 itemID: String,
                 loaderBackend: MediaBackendKind? = nil,
                 loaderAuthority: BrowseSessionAuthority? = nil,
                 load: @escaping @MainActor @Sendable () async throws -> MediaItem,
                 isCurrent: @escaping @MainActor @Sendable () -> Bool = { true })
        -> MetadataRequest {
        MetadataRequest(context: context,
                        itemID: itemID,
                        loaderBackend: loaderBackend ?? context.backend,
                        loaderAuthority: loaderAuthority ?? context.authority,
                        load: load,
                        isCurrent: isCurrent)
    }

    func metadata(appModel: AppModel,
                  backend: MediaBackendKind,
                  itemID: String,
                  policy: MetadataReadPolicy) async throws -> MetadataSnapshot {
        try await metadata(for: request(appModel: appModel, backend: backend, itemID: itemID),
                           policy: policy)
    }

    func metadata(for request: MetadataRequest,
                  policy: MetadataReadPolicy) async throws -> MetadataSnapshot {
        try validate(request)
        let key = Key(backend: request.context.backend,
                      authority: request.context.authority,
                      itemID: request.itemID)
        activate(key)

        if policy == .display, let cached = values[key] {
            let instant = now()
            if instant < cached.freshUntil {
                return snapshot(cached, key: key, delivery: .freshDisplayReuse)
            }
            if instant < cached.staleUntil {
                if flights[key] == nil {
                    _ = startFlight(for: key,
                                    request: request,
                                    preserveCachedValueOnFailure: true)
                }
                return snapshot(cached, key: key, delivery: .staleWhileRevalidate)
            }
            values.removeValue(forKey: key)
        }

        // Both policies may join the exact native read already on the wire. A display caller with
        // a still-usable stale value returned above instead of waiting for this refresh.
        if let flight = flights[key] {
            let loaded = try await Self.awaitWithoutCancellingSharedTask(flight.task)
            if let beforeNativeDelivery { await beforeNativeDelivery() }
            guard request.isCurrent() else { throw MetadataRepositoryError.authorityExpired }
            return snapshot(reconcilingWatchedPatch(in: loaded, for: key),
                            for: request,
                            delivery: .nativeRead)
        }

        // Authoritative work replaces display cache immediately and never falls back after error.
        values.removeValue(forKey: key)
        let task = startFlight(for: key,
                               request: request,
                               preserveCachedValueOnFailure: false)
        let loaded = try await Self.awaitWithoutCancellingSharedTask(task)
        if let beforeNativeDelivery { await beforeNativeDelivery() }
        guard request.isCurrent() else { throw MetadataRepositoryError.authorityExpired }
        return snapshot(reconcilingWatchedPatch(in: loaded, for: key),
                        for: request,
                        delivery: .nativeRead)
    }

    /// Apply only a successfully accepted watched mutation to presentation cache. The exact
    /// authority must still be live; this method never starts a request and never upgrades cache
    /// provenance into action authority.
    func patchWatchedState(appModel: AppModel,
                           backend: MediaBackendKind,
                           authority: BrowseSessionAuthority,
                           itemID: String,
                           played: Bool) throws {
        guard appModel.authenticatedBrowseSession(for: backend)?.authority == authority else {
            throw MetadataRepositoryError.authorityExpired
        }
        patchWatchedState(backend: backend,
                          authority: authority,
                          itemID: itemID,
                          played: played)
    }

    /// Repository-owned action admission. Snapshot provenance alone is insufficient: a once-
    /// native value becomes presentation-only when its TTL expires, a newer source revision is
    /// published, or watched mutation patches the current value.
    func mayAuthorizeAction(_ snapshot: MetadataSnapshot,
                            appModel: AppModel,
                            backend expectedBackend: MediaBackendKind,
                            itemID expectedItemID: String) -> Bool {
        guard snapshot.mayAuthorizeAction(in: appModel,
                                          backend: expectedBackend,
                                          itemID: expectedItemID) else { return false }
        let key = Key(backend: snapshot.backend,
                      authority: snapshot.authority,
                      itemID: snapshot.item.ratingKey)
        guard currentAuthorityByBackend[key.backend] == key.authority,
              let current = values[key] else { return false }
        return current.sourceRevision == snapshot.sourceRevision
            && !current.watchedStatePatched
            && now() < current.freshUntil
    }

    /// Injectable exact-authority patch seam for deterministic ordering tests.
    func patchWatchedState(backend: MediaBackendKind,
                           authority: BrowseSessionAuthority,
                           itemID: String,
                           played: Bool) {
        let key = Key(backend: backend, authority: authority, itemID: itemID)
        guard currentAuthorityByBackend[backend] == nil
                || currentAuthorityByBackend[backend] == authority else { return }
        nextWatchedPatchRevision &+= 1
        watchedPatches[key] = WatchedPatch(revision: nextWatchedPatchRevision, played: played)
        guard let cached = values[key] else { return }
        values[key] = CachedValue(item: MetadataItemCopy.withPlayed(cached.item, played: played),
                                  sourceRevision: cached.sourceRevision,
                                  freshUntil: cached.freshUntil,
                                  staleUntil: cached.staleUntil,
                                  watchedStatePatched: true)
    }

    private func validate(_ request: MetadataRequest) throws {
        guard request.loaderBackend == request.context.backend else {
            throw MetadataRepositoryError.backendMismatch
        }
        guard request.loaderAuthority == request.context.authority else {
            throw MetadataRepositoryError.authorityMismatch
        }
        guard request.isCurrent() else { throw MetadataRepositoryError.authorityExpired }
    }

    private func startFlight(for key: Key,
                             request: MetadataRequest,
                             preserveCachedValueOnFailure: Bool) -> Task<LoadedMetadata, Error> {
        nextGeneration &+= 1
        let generation = nextGeneration
        let patchRevisionAtStart = watchedPatches[key]?.revision ?? 0
        let task = Task { @MainActor [weak self] in
            do {
                guard request.isCurrent() else {
                    throw MetadataRepositoryError.authorityExpired
                }
                let item = try await request.load()
                guard request.isCurrent() else {
                    self?.evictFlight(for: key,
                                      generation: generation,
                                      preserveCachedValue: preserveCachedValueOnFailure)
                    throw MetadataRepositoryError.authorityExpired
                }
                guard let self else {
                    return LoadedMetadata(item: item,
                                          sourceRevision: generation,
                                          watchedStatePatched: false,
                                          appliedWatchedPatchRevision: 0)
                }
                return self.publish(item,
                                    for: key,
                                    generation: generation,
                                    patchRevisionAtStart: patchRevisionAtStart)
            } catch {
                self?.evictFlight(for: key,
                                  generation: generation,
                                  preserveCachedValue: preserveCachedValueOnFailure)
                throw error
            }
        }
        flights[key] = InFlight(generation: generation, task: task)
        return task
    }

    private func snapshot(_ value: CachedValue,
                          key: Key,
                          delivery: MetadataDeliveryProvenance) -> MetadataSnapshot {
        MetadataSnapshot(backend: key.backend,
                         authority: key.authority,
                         sourceRevision: value.sourceRevision,
                         item: value.item,
                         provenance: MetadataProvenance(delivery: delivery,
                                                        watchedStatePatched: value.watchedStatePatched))
    }

    private func snapshot(_ loaded: LoadedMetadata,
                          for request: MetadataRequest,
                          delivery: MetadataDeliveryProvenance) -> MetadataSnapshot {
        MetadataSnapshot(backend: request.context.backend,
                         authority: request.context.authority,
                         sourceRevision: loaded.sourceRevision,
                         item: loaded.item,
                         provenance: MetadataProvenance(delivery: delivery,
                                                        watchedStatePatched: loaded.watchedStatePatched))
    }

    private func activate(_ key: Key) {
        guard currentAuthorityByBackend[key.backend] != key.authority else { return }
        currentAuthorityByBackend[key.backend] = key.authority
        values = values.filter { candidate, _ in
            candidate.backend != key.backend || candidate.authority == key.authority
        }
        flights = flights.filter { candidate, _ in
            candidate.backend != key.backend || candidate.authority == key.authority
        }
        watchedPatches = watchedPatches.filter { candidate, _ in
            candidate.backend != key.backend || candidate.authority == key.authority
        }
    }

    private func publish(_ item: MediaItem,
                         for key: Key,
                         generation: UInt64,
                         patchRevisionAtStart: UInt64) -> LoadedMetadata {
        guard currentAuthorityByBackend[key.backend] == key.authority,
              let current = flights[key],
              current.generation == generation else {
            return LoadedMetadata(item: item,
                                  sourceRevision: generation,
                                  watchedStatePatched: false,
                                  appliedWatchedPatchRevision: 0)
        }
        flights.removeValue(forKey: key)

        let loaded: LoadedMetadata
        if let patch = watchedPatches[key], patch.revision > patchRevisionAtStart {
            loaded = LoadedMetadata(item: MetadataItemCopy.withPlayed(item, played: patch.played),
                                    sourceRevision: generation,
                                    watchedStatePatched: true,
                                    appliedWatchedPatchRevision: patch.revision)
        } else {
            // A native read that started after the mutation is the newer authority.
            watchedPatches.removeValue(forKey: key)
            loaded = LoadedMetadata(item: item,
                                    sourceRevision: generation,
                                    watchedStatePatched: false,
                                    appliedWatchedPatchRevision: 0)
        }

        let instant = now()
        values[key] = CachedValue(
            item: loaded.item,
            sourceRevision: loaded.sourceRevision,
            freshUntil: Self.deadline(after: freshDisplayTTLNanoseconds, from: instant),
            staleUntil: Self.deadline(after: staleDisplayTTLNanoseconds, from: instant),
            watchedStatePatched: loaded.watchedStatePatched)
        return loaded
    }

    /// Close the publication-to-waiter hand-off race: a server-accepted watched mutation can
    /// arrive after `publish` has completed but before a waiter resumes on the main actor. Such a
    /// waiter receives the patched presentation value and, critically, patched provenance rather
    /// than an apparently authoritative native snapshot.
    private func reconcilingWatchedPatch(in loaded: LoadedMetadata, for key: Key)
        -> LoadedMetadata {
        guard let patch = watchedPatches[key],
              patch.revision > loaded.appliedWatchedPatchRevision else { return loaded }
        return LoadedMetadata(item: MetadataItemCopy.withPlayed(loaded.item,
                                                                played: patch.played),
                              sourceRevision: loaded.sourceRevision,
                              watchedStatePatched: true,
                              appliedWatchedPatchRevision: patch.revision)
    }

    private func evictFlight(for key: Key,
                             generation: UInt64,
                             preserveCachedValue: Bool) {
        guard let current = flights[key], current.generation == generation else { return }
        flights.removeValue(forKey: key)
        if !preserveCachedValue { values.removeValue(forKey: key) }
    }

    private static func deadline(after interval: UInt64, from instant: UInt64) -> UInt64 {
        let (deadline, overflow) = instant.addingReportingOverflow(interval)
        return overflow ? UInt64.max : deadline
    }

    private static func awaitWithoutCancellingSharedTask(
        _ task: Task<LoadedMetadata, Error>
    ) async throws -> LoadedMetadata {
        let waiter = SharedTaskWaiter<LoadedMetadata>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task {
                    do { waiter.resolve(.success(try await task.value)) }
                    catch { waiter.resolve(.failure(error)) }
                }
            }
        } onCancel: {
            waiter.resolve(.failure(CancellationError()))
        }
    }
}

/// Full-field copy used only for a server-accepted watched-state patch.
private enum MetadataItemCopy {
    static func withPlayed(_ item: MediaItem, played: Bool) -> MediaItem {
        MediaItem(ratingKey: item.ratingKey, key: item.key, title: item.title, type: item.type,
                  subtype: item.subtype, duration: item.duration, viewOffset: item.viewOffset,
                  viewCount: played ? max(1, item.viewCount ?? 0) : 0,
                  year: item.year, summary: item.summary, thumb: item.thumb, art: item.art,
                  media: item.media, librarySectionID: item.librarySectionID,
                  librarySectionKey: item.librarySectionKey, chapters: item.chapters,
                  markers: item.markers, rating: item.rating, contentRating: item.contentRating,
                  tagline: item.tagline, genres: item.genres, criticRating: item.criticRating,
                  roles: item.roles, directors: item.directors, studios: item.studios,
                  logo: item.logo, grandparentTitle: item.grandparentTitle,
                  grandparentRatingKey: item.grandparentRatingKey,
                  grandparentThumb: item.grandparentThumb, parentTitle: item.parentTitle,
                  parentRatingKey: item.parentRatingKey, parentThumb: item.parentThumb,
                  parentIndex: item.parentIndex, index: item.index,
                  originalTitle: item.originalTitle, lastViewedAt: item.lastViewedAt,
                  parentYear: item.parentYear, ratingCount: item.ratingCount,
                  composite: item.composite, leafCount: item.leafCount,
                  playlistType: item.playlistType,
                  primaryImageAspectRatio: item.primaryImageAspectRatio,
                  versions: item.versions, providerIds: item.providerIds,
                  relatedItems: item.relatedItems,
                  relatedAvailability: item.relatedAvailability)
    }
}
