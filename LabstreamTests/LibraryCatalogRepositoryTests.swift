import Foundation
import Testing
@testable import Labstream
@testable import PMSKit

@Suite("Library catalog repository")
@MainActor
struct LibraryCatalogRepositoryTests {
    @Test(arguments: [MediaBackendKind.plex, .jellyfin, .emby])
    func searchAndMusicShareOneBackendCatalogWhenOneConsumerCancels(
        backend: MediaBackendKind
    ) async throws {
        let context = makeDetachedContext(backend: backend)
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let request = repository.request(context: context,
                                         loader: loader(for: context, fetch: fetch))

        let search = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 1)
        let music = Task { try await repository.catalog(for: request).descriptors }
        await Task.yield()
        search.cancel()
        do {
            _ = try await search.value
            Issue.record("The cancelled Search waiter must return promptly")
        } catch is CancellationError {
            // Music still owns the shared native enumeration.
        }

        let expected = descriptors("video", "music", backend: backend)
        await fetch.succeed(attempt: 0, with: expected)
        #expect(try await music.value == expected)
        #expect(try await repository.catalog(for: request).descriptors == expected)
        #expect(await fetch.startedCount == 1)
    }

    @Test func concurrentReadersShareOneNativeReadAndPreserveOrder() async throws {
        let context = try makeContext()
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let loader = loader(for: context, fetch: fetch)

        let request = repository.request(context: context, loader: loader)
        let first = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 1)
        let second = Task { try await repository.catalog(for: request).descriptors }
        await Task.yield()

        let expected = descriptors("shows", "movies", "music")
        await fetch.succeed(attempt: 0, with: expected)
        #expect(try await first.value == expected)
        #expect(try await second.value == expected)
        #expect(await fetch.startedCount == 1)

        #expect(try await repository.catalog(for: request).descriptors == expected)
        #expect(await fetch.startedCount == 1)
    }

    @Test func cancelledWaiterReturnsPromptlyWithoutPoisoningSharedRead() async throws {
        let context = try makeContext()
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let loader = loader(for: context, fetch: fetch)

        let request = repository.request(context: context, loader: loader)
        let cancelled = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 1)
        let survivor = Task { try await repository.catalog(for: request).descriptors }
        await Task.yield()

        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled catalog waiter must throw")
        } catch is CancellationError {
            // The native request remains owned by the repository, not this waiter.
        }
        #expect(await fetch.startedCount == 1)

        let expected = descriptors("survivor")
        await fetch.succeed(attempt: 0, with: expected)
        #expect(try await survivor.value == expected)
        #expect(try await repository.catalog(for: request).descriptors == expected)
        #expect(await fetch.startedCount == 1)
    }

    @Test func allCancelledWaitersLeaveSharedReadAliveForEventualCachePublication() async throws {
        let context = try makeContext()
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let request = repository.request(context: context,
                                         loader: loader(for: context, fetch: fetch))

        let first = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 1)
        let second = Task { try await repository.catalog(for: request).descriptors }
        await Task.yield()
        first.cancel()
        second.cancel()

        for waiter in [first, second] {
            do {
                _ = try await waiter.value
                Issue.record("Every cancelled waiter must return CancellationError promptly")
            } catch is CancellationError {
                // The repository, not any individual waiter, owns the native read.
            }
        }

        let eventual = descriptors("eventual-cache")
        await fetch.succeed(attempt: 0, with: eventual)
        await Task.yield()
        #expect(try await repository.catalog(for: request).descriptors == eventual)
        #expect(await fetch.startedCount == 1)
    }

    @Test func failedLoadIsEvictedAndNextReaderRetries() async throws {
        let context = try makeContext()
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let loader = loader(for: context, fetch: fetch)

        let request = repository.request(context: context, loader: loader)
        let failed = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 1)
        await fetch.fail(attempt: 0)
        do {
            _ = try await failed.value
            Issue.record("Injected catalog failure must propagate")
        } catch is ControlledCatalogFetch.Failure {
            // Expected.
        }

        let retry = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 2)
        let expected = descriptors("retry")
        await fetch.succeed(attempt: 1, with: expected)
        #expect(try await retry.value == expected)
        #expect(await fetch.startedCount == 2)
    }

    @Test func mismatchedBackendNeverStartsLoader() async throws {
        let context = try makeContext()
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let wrongLoader = LibraryCatalogLoader(backend: .emby,
                                               authority: context.authority) {
            try await fetch.fetch()
        }
        let request = repository.request(context: context, loader: wrongLoader)

        do {
            _ = try await repository.catalog(for: request)
            Issue.record("Repository must reject a loader from another backend")
        } catch let error as LibraryCatalogRepositoryError {
            #expect(error == .backendMismatch)
        }
        #expect(await fetch.startedCount == 0)
    }

    @Test func forceRefreshSeriallyReplacesInFlightValueForSubsequentReaders() async throws {
        let context = try makeContext()
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let loader = loader(for: context, fetch: fetch)

        let request = repository.request(context: context, loader: loader)
        let original = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 1)
        let refresh = Task {
            try await repository.catalog(for: request, forceRefresh: true).descriptors
        }
        await Task.yield()
        // Force replaces the public entry immediately but waits for the on-wire read. There is
        // still exactly one native request for this authority at a time.
        #expect(await fetch.startedCount == 1)

        let old = descriptors("old")
        await fetch.succeed(attempt: 0, with: old)
        #expect(try await original.value == old)
        await fetch.waitUntilStarted(count: 2)

        let joinsReplacement = Task { try await repository.catalog(for: request).descriptors }
        await Task.yield()
        #expect(await fetch.startedCount == 2)
        let fresh = descriptors("fresh", "native-order")
        await fetch.succeed(attempt: 1, with: fresh)

        #expect(try await refresh.value == fresh)
        #expect(try await joinsReplacement.value == fresh)
        #expect(try await repository.catalog(for: request).descriptors == fresh)
        #expect(await fetch.startedCount == 2)
    }

    @Test func failedForceRefreshEvictsReplacedValueInsteadOfServingStaleFallback() async throws {
        let context = try makeContext()
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let loader = loader(for: context, fetch: fetch)

        let request = repository.request(context: context, loader: loader)
        let initial = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 1)
        await fetch.succeed(attempt: 0, with: descriptors("initial"))
        _ = try await initial.value

        let refresh = Task {
            try await repository.catalog(for: request, forceRefresh: true).descriptors
        }
        await fetch.waitUntilStarted(count: 2)
        await fetch.fail(attempt: 1)
        do {
            _ = try await refresh.value
            Issue.record("Failed force refresh must propagate")
        } catch is ControlledCatalogFetch.Failure {
            // Expected; the replaced value is not a stale fallback.
        }

        let retry = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 3)
        let recovered = descriptors("recovered")
        await fetch.succeed(attempt: 2, with: recovered)
        #expect(try await retry.value == recovered)
        #expect(await fetch.startedCount == 3)
    }

    @Test func chainedForceRefreshesStaySerialAndLatestSuccessOwnsCache() async throws {
        let context = try makeContext()
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let request = repository.request(context: context,
                                         loader: loader(for: context, fetch: fetch))

        let original = Task { try await repository.catalog(for: request).descriptors }
        await fetch.waitUntilStarted(count: 1)
        let firstRefresh = Task {
            try await repository.catalog(for: request, forceRefresh: true).descriptors
        }
        await Task.yield()
        let secondRefresh = Task {
            try await repository.catalog(for: request, forceRefresh: true).descriptors
        }
        await Task.yield()
        #expect(await fetch.startedCount == 1)

        let originalValue = descriptors("original")
        await fetch.succeed(attempt: 0, with: originalValue)
        #expect(try await original.value == originalValue)
        await fetch.waitUntilStarted(count: 2)
        #expect(await fetch.maximumActiveCount == 1)

        await fetch.fail(attempt: 1)
        do {
            _ = try await firstRefresh.value
            Issue.record("The first forced failure must propagate")
        } catch is ControlledCatalogFetch.Failure {
            // The next forced read still starts after this failure.
        }
        await fetch.waitUntilStarted(count: 3)
        let latest = descriptors("latest")
        await fetch.succeed(attempt: 2, with: latest)
        #expect(try await secondRefresh.value == latest)
        #expect(await fetch.maximumActiveCount == 1)
        #expect(try await repository.catalog(for: request).descriptors == latest)
    }

    @Test func queuedForceRefreshNeverStartsAfterAuthorityExpires() async throws {
        let model = makeModel()
        model.applyMediaBrowserSession(backend: .jellyfin,
                                       server: URL(string: "https://jellyfin.example.test")!,
                                       token: "token-A",
                                       userID: "user",
                                       serverID: "server")
        let context = try #require(model.activeAuthenticatedBrowseSession)
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let request = repository.request(
            appModel: model,
            context: context,
            loader: loader(for: context, fetch: fetch)
        )

        let initial = Task { try await repository.catalog(for: request) }
        await fetch.waitUntilStarted(count: 1)
        let queuedRefresh = Task {
            try await repository.catalog(for: request, forceRefresh: true)
        }
        await Task.yield()
        #expect(await fetch.startedCount == 1)

        model.jellyfinAccessToken = "token-B"
        await fetch.succeed(attempt: 0, with: descriptors("expired-in-flight"))

        for task in [initial, queuedRefresh] {
            do {
                _ = try await task.value
                Issue.record("Expired in-flight and queued work must reject its stale authority")
            } catch let error as LibraryCatalogRepositoryError {
                #expect(error == .authorityExpired)
            }
        }
        #expect(await fetch.startedCount == 1)
    }

    @Test func delayedOldAuthorityCannotReplaceOrValidateAsCurrent() async throws {
        let model = makeModel()
        model.applyMediaBrowserSession(backend: .jellyfin,
                                       server: URL(string: "https://jellyfin.example.test")!,
                                       token: "token-A",
                                       userID: "user",
                                       serverID: "server")
        let oldContext = try #require(model.activeAuthenticatedBrowseSession)
        let oldFetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let oldRequest = repository.request(
            context: oldContext,
            loader: loader(for: oldContext, fetch: oldFetch),
            isCurrent: { [weak model] in
                model?.activeAuthenticatedBrowseSession?.authority == oldContext.authority
            }
        )
        let oldTask = Task {
            try await repository.catalog(for: oldRequest)
        }
        await oldFetch.waitUntilStarted(count: 1)

        model.jellyfinAccessToken = "token-B"
        let currentContext = try #require(model.activeAuthenticatedBrowseSession)
        let currentFetch = ControlledCatalogFetch()
        let currentRequest = repository.request(
            context: currentContext,
            loader: loader(for: currentContext, fetch: currentFetch),
            isCurrent: { [weak model] in
                model?.activeAuthenticatedBrowseSession?.authority == currentContext.authority
            }
        )
        let currentTask = Task { try await repository.catalog(for: currentRequest) }
        await currentFetch.waitUntilStarted(count: 1)
        let current = descriptors("current")
        await currentFetch.succeed(attempt: 0, with: current)
        #expect(try await currentTask.value.descriptors == current)

        let delayed = descriptors("delayed-old")
        await oldFetch.succeed(attempt: 0, with: delayed)
        do {
            _ = try await oldTask.value
            Issue.record("An expired authority must not return or publish a delayed result")
        } catch let error as LibraryCatalogRepositoryError {
            #expect(error == .authorityExpired)
        }

        let unusedFetch = ControlledCatalogFetch()
        let cachedRequest = repository.request(
            context: currentContext,
            loader: loader(for: currentContext, fetch: unusedFetch),
            isCurrent: { true }
        )
        #expect(try await repository.catalog(for: cachedRequest).descriptors == current)
        #expect(await unusedFetch.startedCount == 0)

        let oldSnapshot = LibraryCatalogSnapshot(backend: oldContext.backend,
                                                 authority: oldContext.authority,
                                                 descriptors: delayed)
        let currentSnapshot = LibraryCatalogSnapshot(backend: currentContext.backend,
                                                     authority: currentContext.authority,
                                                     descriptors: current)
        #expect(!oldSnapshot.isCurrent(in: model))
        #expect(currentSnapshot.isCurrent(in: model))
    }

    @Test func delayedInvocationOfExpiredRequestCannotReactivateOldAuthorityOrEvictCurrent() async throws {
        let model = makeModel()
        model.applyMediaBrowserSession(backend: .jellyfin,
                                       server: URL(string: "https://jellyfin.example.test")!,
                                       token: "token-A",
                                       userID: "user",
                                       serverID: "server")
        let repository = LibraryCatalogRepository()
        let oldContext = try #require(model.activeAuthenticatedBrowseSession)
        let oldFetch = ControlledCatalogFetch()
        let oldRequest = repository.request(
            appModel: model,
            context: oldContext,
            loader: loader(for: oldContext, fetch: oldFetch)
        )

        model.jellyfinAccessToken = "token-B"
        let currentContext = try #require(model.activeAuthenticatedBrowseSession)
        let currentFetch = ControlledCatalogFetch()
        let currentRequest = repository.request(
            context: currentContext,
            loader: loader(for: currentContext, fetch: currentFetch),
            isCurrent: { [weak model] in
                model?.activeAuthenticatedBrowseSession?.authority == currentContext.authority
            }
        )
        let currentTask = Task { try await repository.catalog(for: currentRequest) }
        await currentFetch.waitUntilStarted(count: 1)
        let current = descriptors("current")
        await currentFetch.succeed(attempt: 0, with: current)
        #expect(try await currentTask.value.descriptors == current)

        do {
            _ = try await repository.catalog(for: oldRequest)
            Issue.record("A request captured under an expired authority must fail before loading")
        } catch let error as LibraryCatalogRepositoryError {
            #expect(error == .authorityExpired)
        }
        #expect(await oldFetch.startedCount == 0)

        let cacheProbe = ControlledCatalogFetch()
        let probeRequest = repository.request(
            context: currentContext,
            loader: loader(for: currentContext, fetch: cacheProbe)
        )
        #expect(try await repository.catalog(for: probeRequest).descriptors == current)
        #expect(await cacheProbe.startedCount == 0)
    }

    @Test func sameBackendLoaderFromAnotherAuthorityIsRejectedBeforeFetch() async throws {
        let first = try makeContext(token: "token-A")
        let second = try makeContext(token: "token-B")
        let fetch = ControlledCatalogFetch()
        let repository = LibraryCatalogRepository()
        let wrongAuthorityLoader = loader(for: second, fetch: fetch)
        let request = repository.request(context: first, loader: wrongAuthorityLoader)

        do {
            _ = try await repository.catalog(for: request)
            Issue.record("A same-backend loader from another authority must be rejected")
        } catch let error as LibraryCatalogRepositoryError {
            #expect(error == .authorityMismatch)
        }
        #expect(await fetch.startedCount == 0)
    }

    @Test func switchingBackendsRetainsAndIsolatesEachExactAuthorityCache() async throws {
        let model = makeModel()
        model.applyMediaBrowserSession(backend: .jellyfin,
                                       server: URL(string: "https://jellyfin.example.test")!,
                                       token: "jf-token",
                                       userID: "jf-user",
                                       serverID: "jf-server")
        model.applyMediaBrowserSession(backend: .emby,
                                       server: URL(string: "https://emby.example.test")!,
                                       token: "emby-token",
                                       userID: "emby-user",
                                       serverID: "emby-server")
        let repository = LibraryCatalogRepository()

        let jellyfinContext = try #require(model.authenticatedBrowseSession(for: .jellyfin))
        let jellyfinFetch = ControlledCatalogFetch()
        let jellyfinRequest = repository.request(
            appModel: model,
            context: jellyfinContext,
            loader: loader(for: jellyfinContext, fetch: jellyfinFetch)
        )
        let jellyfinTask = Task { try await repository.catalog(for: jellyfinRequest) }
        await jellyfinFetch.waitUntilStarted(count: 1)
        let jellyfinValue = descriptors("jellyfin", backend: .jellyfin)
        await jellyfinFetch.succeed(attempt: 0, with: jellyfinValue)
        #expect(try await jellyfinTask.value.descriptors == jellyfinValue)

        model.activeBackend = .emby
        let embyContext = try #require(model.activeAuthenticatedBrowseSession)
        let embyFetch = ControlledCatalogFetch()
        let embyRequest = repository.request(
            appModel: model,
            context: embyContext,
            loader: loader(for: embyContext, fetch: embyFetch)
        )
        let embyTask = Task { try await repository.catalog(for: embyRequest) }
        await embyFetch.waitUntilStarted(count: 1)
        let embyValue = descriptors("emby", backend: .emby)
        await embyFetch.succeed(attempt: 0, with: embyValue)
        #expect(try await embyTask.value.descriptors == embyValue)

        model.activeBackend = .jellyfin
        let jellyfinProbe = ControlledCatalogFetch()
        let jellyfinProbeRequest = repository.request(
            appModel: model,
            context: jellyfinContext,
            loader: loader(for: jellyfinContext, fetch: jellyfinProbe)
        )
        #expect(try await repository.catalog(for: jellyfinProbeRequest).descriptors == jellyfinValue)
        #expect(await jellyfinProbe.startedCount == 0)

        model.activeBackend = .emby
        let embyProbe = ControlledCatalogFetch()
        let embyProbeRequest = repository.request(
            appModel: model,
            context: embyContext,
            loader: loader(for: embyContext, fetch: embyProbe)
        )
        #expect(try await repository.catalog(for: embyProbeRequest).descriptors == embyValue)
        #expect(await embyProbe.startedCount == 0)
    }

    @Test func runtimeAndFourEnumerationConsumersUseOneInjectedRepository() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let runtime = try String(contentsOf: root.appendingPathComponent(
            "Labstream/Shared/App/AppRuntime.swift"), encoding: .utf8)
        #expect(runtime.contains("let libraryCatalogRepository = LibraryCatalogRepository()"))

        let shellSources = try [
            "Labstream/Platforms/visionOS/UI/VisionRootShell.swift",
            "Labstream/Platforms/Mobile/UI/MobileRootShell.swift",
            "Labstream/Platforms/macOS/UI/MacRootShell.swift",
            "Labstream/Platforms/tvOS/UI/TVRootShell.swift",
        ].map {
            try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)
        }
        #expect(shellSources.allSatisfy {
            $0.contains("catalogRepository: runtime.libraryCatalogRepository")
        })

        for path in [
            "Labstream/Shared/UI/LibraryGridView.swift",
            "Labstream/Platforms/macOS/UI/MacSidebarPolicy.swift",
            "Labstream/Shared/UI/LibraryVisibilityEditor.swift",
            "Labstream/Shared/UI/MediaBrowserHomeProvider.swift",
        ] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            #expect(source.contains("catalogRepository.catalog"), "Missing repository use in \(path)")
        }
    }

    private func makeContext(token: String = "token") throws -> AuthenticatedBrowseSessionContext {
        let model = makeModel()
        model.applyMediaBrowserSession(backend: .jellyfin,
                                       server: URL(string: "https://jellyfin.example.test")!,
                                       token: token,
                                       userID: "user",
                                       serverID: "server")
        return try #require(model.activeAuthenticatedBrowseSession)
    }

    private func makeModel() -> AppModel {
        AppModel(identity: ClientIdentity(clientIdentifier: "catalog-repository-test",
                                          product: "Labstream",
                                          version: "1",
                                          deviceName: "Test"),
                 activeBackend: .jellyfin)
    }

    private func makeDetachedContext(backend: MediaBackendKind) -> AuthenticatedBrowseSessionContext {
        AuthenticatedBrowseSessionContext(
            backend: backend,
            session: BackendSession(kind: backend,
                                    baseURL: URL(string: "https://catalog.example.test")!,
                                    token: "token",
                                    userID: backend == .plex ? nil : "user",
                                    serverID: "server"),
            clientIdentity: ClientIdentity(clientIdentifier: "catalog-consumer-test",
                                           product: "Labstream",
                                           version: "1",
                                           deviceName: "Test"),
            authority: BrowseSessionAuthority()
        )
    }

    private func loader(for context: AuthenticatedBrowseSessionContext,
                        fetch: ControlledCatalogFetch) -> LibraryCatalogLoader {
        LibraryCatalogLoader(backend: context.backend,
                             authority: context.authority) {
            try await fetch.fetch()
        }
    }

    private func descriptors(_ ids: String...,
                             backend: MediaBackendKind = .jellyfin) -> [LibraryCatalogDescriptor] {
        ids.map { id in
            if backend == .plex {
                return LibraryCatalogDescriptor(
                    plex: PlexSection(key: id,
                                      title: id,
                                      type: id == "music" ? "artist" : "movie"))
            }
            return LibraryCatalogDescriptor(
                mediaBrowser: MediaBrowserLibraryLink(id: id,
                                                      title: id,
                                                      collectionType: id == "music" ? "music" : "movies"),
                backend: backend)
        }
    }
}

private actor ControlledCatalogFetch {
    struct Failure: Error {}

    private var continuations: [Int: CheckedContinuation<[LibraryCatalogDescriptor], Error>] = [:]
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var startedCount = 0
    private(set) var maximumActiveCount = 0
    private var activeCount = 0

    func fetch() async throws -> [LibraryCatalogDescriptor] {
        let attempt = startedCount
        startedCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        resumeStartWaiters()
        return try await withCheckedThrowingContinuation { continuation in
            continuations[attempt] = continuation
        }
    }

    func waitUntilStarted(count: Int) async {
        guard startedCount < count else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append((count, continuation))
        }
    }

    func succeed(attempt: Int, with descriptors: [LibraryCatalogDescriptor]) {
        guard let continuation = continuations.removeValue(forKey: attempt) else { return }
        activeCount -= 1
        continuation.resume(returning: descriptors)
    }

    func fail(attempt: Int) {
        guard let continuation = continuations.removeValue(forKey: attempt) else { return }
        activeCount -= 1
        continuation.resume(throwing: Failure())
    }

    private func resumeStartWaiters() {
        let ready = startWaiters.filter { startedCount >= $0.count }
        startWaiters.removeAll { startedCount >= $0.count }
        for waiter in ready { waiter.continuation.resume() }
    }
}
