import Foundation

/// One authority-fenced catalog result. The authority is intentionally opaque: callers may only
/// use it to prove that the authenticated browse lane which produced this value is still current.
struct LibraryCatalogSnapshot: Sendable {
    let backend: MediaBackendKind
    let authority: BrowseSessionAuthority
    let descriptors: [LibraryCatalogDescriptor]

    @MainActor
    func isCurrent(in appModel: AppModel) -> Bool {
        guard let current = appModel.activeAuthenticatedBrowseSession else { return false }
        return current.backend == backend && current.authority == authority
    }
}

enum LibraryCatalogRepositoryError: Error, LocalizedError, Equatable {
    case noAuthenticatedSession
    case backendMismatch
    case authorityMismatch
    case authorityExpired

    var errorDescription: String? {
        switch self {
        case .noAuthenticatedSession:
            return "No server selected."
        case .backendMismatch:
            return "The library catalog request does not match the authenticated backend."
        case .authorityMismatch:
            return "The library catalog loader does not match the authenticated session."
        case .authorityExpired:
            return "The authenticated library catalog session is no longer current."
        }
    }
}

/// Immutable request authority plus the native loader captured in the same MainActor turn.
struct LibraryCatalogRequest {
    fileprivate let context: AuthenticatedBrowseSessionContext
    fileprivate let loader: LibraryCatalogLoader
    fileprivate let isCurrent: @MainActor @Sendable () -> Bool
}

/// App-lifetime, fresh-only repository for the shared section/view enumeration boundary.
///
/// A successful value is reusable only for the exact backend + opaque authenticated authority
/// that produced it. There is deliberately no TTL, stale-while-revalidate path, stale fallback,
/// or cross-authority lookup. Normal concurrent readers share one task. A force refresh replaces
/// the published entry immediately and serializes its new read behind any existing exact-authority
/// read, so even forced work never creates two simultaneous native catalog requests.
@MainActor
final class LibraryCatalogRepository {
    private struct Key: Hashable {
        let backend: MediaBackendKind
        let authority: BrowseSessionAuthority
    }

    private struct InFlight {
        let generation: UInt64
        let task: Task<[LibraryCatalogDescriptor], Error>
    }

    private enum Entry {
        case value([LibraryCatalogDescriptor])
        case inFlight(InFlight)
    }

    private var entries: [Key: Entry] = [:]
    private var currentKeyByBackend: [MediaBackendKind: Key] = [:]
    private var nextGeneration: UInt64 = 0

    /// Capture the active context and its loader together on MainActor, then resolve only that
    /// immutable authority even if AppModel changes while the request is suspended.
    func catalog(appModel: AppModel,
                 forceRefresh: Bool = false) async throws -> LibraryCatalogSnapshot {
        let request = try request(appModel: appModel)
        return try await catalog(for: request, forceRefresh: forceRefresh)
    }

    func request(appModel: AppModel) throws -> LibraryCatalogRequest {
        guard let context = appModel.activeAuthenticatedBrowseSession else {
            throw LibraryCatalogRepositoryError.noAuthenticatedSession
        }
        return request(appModel: appModel,
                       context: context,
                       loader: LibraryCatalogLoader(appModel: appModel,
                                                    authority: context.authority))
    }

    /// Loader-injectable variant for deterministic execution tests. Currentness still comes from
    /// the live AppModel rather than the injected transport.
    func request(appModel: AppModel,
                 context: AuthenticatedBrowseSessionContext,
                 loader: LibraryCatalogLoader) -> LibraryCatalogRequest {
        let backend = context.backend
        let authority = context.authority
        return LibraryCatalogRequest(
            context: context,
            loader: loader,
            isCurrent: { [weak appModel] in
                guard let current = appModel?.activeAuthenticatedBrowseSession else { return false }
                return current.backend == backend && current.authority == authority
            }
        )
    }

    func catalog(for request: LibraryCatalogRequest,
                 forceRefresh: Bool = false) async throws -> LibraryCatalogSnapshot {
        let descriptors = try await load(for: request, forceRefresh: forceRefresh)
        return LibraryCatalogSnapshot(backend: request.context.backend,
                                      authority: request.context.authority,
                                      descriptors: descriptors)
    }

    /// Injectable request construction seam used by deterministic repository contracts. The
    /// loader and context still have to carry the same opaque authority.
    func request(context: AuthenticatedBrowseSessionContext,
                 loader: LibraryCatalogLoader,
                 isCurrent: @escaping @MainActor @Sendable () -> Bool = { true })
        -> LibraryCatalogRequest {
        LibraryCatalogRequest(context: context, loader: loader, isCurrent: isCurrent)
    }

    private func load(for request: LibraryCatalogRequest,
                      forceRefresh: Bool) async throws -> [LibraryCatalogDescriptor] {
        let context = request.context
        let loader = request.loader
        guard loader.backend == context.backend else {
            throw LibraryCatalogRepositoryError.backendMismatch
        }
        guard loader.authority == context.authority else {
            throw LibraryCatalogRepositoryError.authorityMismatch
        }
        if !request.isCurrent() {
            throw LibraryCatalogRepositoryError.authorityExpired
        }

        let key = Key(backend: context.backend, authority: context.authority)
        activate(key)

        if !forceRefresh, let entry = entries[key] {
            switch entry {
            case .value(let descriptors):
                return descriptors
            case .inFlight(let inFlight):
                return try await Self.awaitWithoutCancellingSharedTask(inFlight.task)
            }
        }

        let predecessor: Task<[LibraryCatalogDescriptor], Error>?
        if forceRefresh, case .inFlight(let inFlight)? = entries[key] {
            predecessor = inFlight.task
        } else {
            predecessor = nil
        }

        nextGeneration &+= 1
        let generation = nextGeneration
        let task = Task { @MainActor [weak self] in
            // Force means "read again", not "overlap the read already on the wire". Waiting for
            // the replaced task also keeps its existing waiters independent and unpoisoned.
            if let predecessor {
                _ = try? await predecessor.value
            }
            do {
                // The authority may expire while a forced read is queued behind its predecessor.
                // Never put the retired session back on the wire after that serialization wait.
                guard request.isCurrent() else {
                    throw LibraryCatalogRepositoryError.authorityExpired
                }
                let descriptors = try await loader.load()
                if !request.isCurrent() {
                    self?.evictFailure(for: key, generation: generation)
                    throw LibraryCatalogRepositoryError.authorityExpired
                }
                self?.publish(descriptors, for: key, generation: generation)
                return descriptors
            } catch {
                self?.evictFailure(for: key, generation: generation)
                throw error
            }
        }
        entries[key] = .inFlight(InFlight(generation: generation, task: task))
        return try await Self.awaitWithoutCancellingSharedTask(task)
    }

    private func activate(_ key: Key) {
        guard currentKeyByBackend[key.backend] != key else { return }
        currentKeyByBackend[key.backend] = key
        // Retire only this backend's superseded authority. Other configured backend lanes keep
        // their exact-authority values across an ordinary backend switch.
        entries = entries.filter { candidate, _ in
            candidate.backend != key.backend || candidate == key
        }
    }

    private func publish(_ descriptors: [LibraryCatalogDescriptor],
                         for key: Key,
                         generation: UInt64) {
        guard currentKeyByBackend[key.backend] == key,
              case .inFlight(let current)? = entries[key],
              current.generation == generation else { return }
        entries[key] = .value(descriptors)
    }

    private func evictFailure(for key: Key, generation: UInt64) {
        guard case .inFlight(let current)? = entries[key],
              current.generation == generation else { return }
        entries.removeValue(forKey: key)
    }

    /// Awaiting `Task.value` directly does not promptly end a cancelled waiter. This small bridge
    /// lets that waiter throw CancellationError while a detached observation keeps the shared
    /// repository task alive for all remaining waiters and for eventual cache publication.
    private static func awaitWithoutCancellingSharedTask(
        _ task: Task<[LibraryCatalogDescriptor], Error>
    ) async throws -> [LibraryCatalogDescriptor] {
        let waiter = LibraryCatalogTaskWaiter<[LibraryCatalogDescriptor]>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.install(continuation)
                Task {
                    do {
                        waiter.resolve(.success(try await task.value))
                    } catch {
                        waiter.resolve(.failure(error))
                    }
                }
            }
        } onCancel: {
            waiter.resolve(.failure(CancellationError()))
        }
    }
}

/// Lock-backed because a task cancellation handler is not actor-isolated and may race installing
/// the continuation. Exactly one outcome wins; later shared-task completion is ignored.
private final class LibraryCatalogTaskWaiter<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isResolved = false

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let result = pendingResult {
            pendingResult = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: sending Result<Value, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(with: result)
        } else {
            pendingResult = result
            lock.unlock()
        }
    }
}
