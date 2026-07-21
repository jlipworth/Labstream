import Foundation
import PMSKit

/// The only tuning surface for burst-prone optional side-asset network traffic.
///
/// The default is intentionally conservative relative to the two-events-per-second
/// CrowdSec leak rate observed during the July 2026 incident. It is an application
/// safety default, not a Plex, Jellyfin, Emby, or CrowdSec protocol constant.
struct SideAssetRequestPolicy: Sendable, Equatable {
    let maximumRequestStartsPerSecond: Double
    let maximumConcurrentRequests: Int

    static let conservativeDefault = SideAssetRequestPolicy(
        maximumRequestStartsPerSecond: 1,
        maximumConcurrentRequests: 2
    )

    init(maximumRequestStartsPerSecond: Double, maximumConcurrentRequests: Int) {
        precondition(maximumRequestStartsPerSecond > 0)
        precondition(maximumConcurrentRequests > 0)
        self.maximumRequestStartsPerSecond = maximumRequestStartsPerSecond
        self.maximumConcurrentRequests = maximumConcurrentRequests
    }

    var minimumStartIntervalNanoseconds: UInt64 {
        UInt64((1_000_000_000 / maximumRequestStartsPerSecond).rounded(.up))
    }
}

/// Stable identifiers deliberately contain no logging or description behavior. Callers
/// can use redacted download/request identities without putting URLs into diagnostics.
struct SideAssetOrigin: Hashable, Sendable { let rawValue: String }
struct SideAssetOwner: Hashable, Sendable { let rawValue: String }
struct SideAssetRequestKey: Hashable, Sendable { let rawValue: String }

struct SideAssetCoordinatorClock: Sendable {
    let nowNanoseconds: @Sendable () -> UInt64
    let sleepUntilNanoseconds: @Sendable (UInt64) async throws -> Void

    static let continuous = SideAssetCoordinatorClock(
        nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
        sleepUntilNanoseconds: { deadline in
            let now = DispatchTime.now().uptimeNanoseconds
            guard deadline > now else { return }
            try await Task.sleep(nanoseconds: deadline - now)
        }
    )
}

/// Coordinates burst-prone optional side assets across downloads and online playback in the
/// process. Pacing and concurrency are isolated per server origin, while owners at an origin are
/// selected round-robin so one chapter-heavy operation cannot monopolize the queue.
actor SideAssetFetchCoordinator {
    static let shared = SideAssetFetchCoordinator()

    typealias FetchOperation = @Sendable () async throws -> Data

    private struct JobKey: Hashable, Sendable {
        let origin: SideAssetOrigin
        let request: SideAssetRequestKey
    }

    private struct Waiter {
        let id: UUID
        let owner: SideAssetOwner
        let continuation: CheckedContinuation<Data, any Error>
    }

    private enum Status { case queued, running }

    private struct Job {
        let key: JobKey
        let operation: FetchOperation
        var waiters: [UUID: Waiter]
        var status: Status
        var queueOwner: SideAssetOwner
        var task: Task<Void, Never>?
        var requeueIfCancelled = false
    }

    private struct OriginState {
        var activeCount = 0
        var lastStartNanoseconds: UInt64?
        var ownerQueues: [SideAssetOwner: [JobKey]] = [:]
        var ownerOrder: [SideAssetOwner] = []
        var nextOwnerIndex = 0
        var wakeScheduled = false
    }

    private enum Completion: Sendable {
        case success(Data)
        case failure(any Error)
    }

    private let policy: SideAssetRequestPolicy
    private let clock: SideAssetCoordinatorClock
    private var jobs: [JobKey: Job] = [:]
    /// Exact reverse ownership for waiter cancellation. Cancellation handlers may run on any
    /// executor, but all index mutation is serialized by this actor.
    private var waiterJobs: [UUID: JobKey] = [:]
    private var origins: [SideAssetOrigin: OriginState] = [:]
    private var parkedOwners: Set<SideAssetOwner> = []
#if DEBUG
    struct AdmissionForTesting: Sendable {
        let owner: SideAssetOwner
        let timeNanoseconds: UInt64
    }
    private var admissionsForTesting: [AdmissionForTesting] = []
#endif

    init(
        policy: SideAssetRequestPolicy = .conservativeDefault,
        clock: SideAssetCoordinatorClock = .continuous
    ) {
        self.policy = policy
        self.clock = clock
    }

    func fetch(
        origin: SideAssetOrigin,
        owner: SideAssetOwner,
        requestKey: SideAssetRequestKey,
        existingFile: URL? = nil,
        operation: @escaping FetchOperation
    ) async throws -> Data {
        try Task.checkCancellation()
        if let existingFile,
           let data = try? Data(contentsOf: existingFile),
           !data.isEmpty {
            try Task.checkCancellation()
            return data
        }

        let waiterID = UUID()
        let result: Result<Data, any Error>
        do {
            result = .success(try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    enqueue(
                        waiterID: waiterID,
                        origin: origin,
                        owner: owner,
                        requestKey: requestKey,
                        operation: operation,
                        isCancelled: Task.isCancelled,
                        continuation: continuation
                    )
                }
            } onCancel: {
                Task { await self.cancelWaiter(waiterID) }
            })
        } catch {
            result = .failure(error)
        }
        // Completion and the cancellation-handler hop to this actor can arrive in either order.
        // Check after either continuation outcome so cancellation remains externally deterministic
        // without attempting to resume a continuation for a second time.
        try Task.checkCancellation()
        switch result {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    /// Routes an authenticated optional HTTP asset through the same process-wide origin policy
    /// used by download hydration. Player chapter rails can otherwise create one URLSession task
    /// per chapter in a single render pass, which is indistinguishable from a crawler to common
    /// ingress protection. Request identity remains process-local because it can contain tokens.
    func fetch(request: URLRequest,
               owner: SideAssetOwner,
               existingFile: URL? = nil,
               session: URLSession = .shared,
               operation injectedOperation: FetchOperation? = nil) async throws -> Data {
        guard let url = request.url,
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { throw SideAssetFetchError.invalidOrigin }
        let effectivePort = url.port ?? (scheme == "https" ? 443 : 80)
        let origin = SideAssetOrigin(rawValue: "\(scheme)://\(host):\(effectivePort)")

        var requestIdentity = "\(request.httpMethod ?? "GET")\u{0}\(url.absoluteString)"
        for (name, value) in request.allHTTPHeaderFields?.sorted(by: {
            if $0.key != $1.key { return $0.key < $1.key }
            return $0.value < $1.value
        }) ?? [] {
            requestIdentity += "\u{0}\(name):\(value)"
        }
        if let body = request.httpBody { requestIdentity += "\u{0}\(body.base64EncodedString())" }

        let operation: FetchOperation = injectedOperation ?? {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                throw SideAssetFetchError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            guard !data.isEmpty else { throw SideAssetFetchError.emptyResponse }
            return data
        }
        return try await fetch(origin: origin,
                               owner: owner,
                               requestKey: SideAssetRequestKey(rawValue: requestIdentity),
                               existingFile: existingFile,
                               operation: operation)
    }

    /// Parked work retains its place. In-flight work is cooperatively cancelled and
    /// requeued when every interested owner is parked.
    func setParked(_ parked: Bool, for owner: SideAssetOwner) {
        if parked { parkedOwners.insert(owner) } else { parkedOwners.remove(owner) }

        for key in Array(jobs.keys) {
            guard var job = jobs[key] else { continue }
            if job.status == .queued {
                reassignQueueOwnerIfNeeded(&job)
                jobs[key] = job
            } else if allWaitersParked(job) {
                job.requeueIfCancelled = true
                job.task?.cancel()
                jobs[key] = job
            }
        }
        scheduleAllOrigins()
    }

    /// Permanently cancels one owner's interest. A shared request continues if another
    /// owner is still waiting for the identical asset.
    func cancel(owner: SideAssetOwner) {
        parkedOwners.remove(owner)
        for key in Array(jobs.keys) {
            guard var job = jobs[key] else { continue }
            let cancelled = job.waiters.values.filter { $0.owner == owner }
            for waiter in cancelled {
                job.waiters.removeValue(forKey: waiter.id)
                waiterJobs.removeValue(forKey: waiter.id)
                waiter.continuation.resume(throwing: CancellationError())
            }
            if job.waiters.isEmpty {
                if job.status == .running {
                    job.task?.cancel()
                    jobs[key] = job
                } else {
                    jobs.removeValue(forKey: key)
                }
            } else {
                reassignQueueOwnerIfNeeded(&job)
                jobs[key] = job
            }
        }
        compactAllOrigins()
        scheduleAllOrigins()
    }

#if DEBUG
    func waiterCountForTesting(origin: SideAssetOrigin,
                               requestKey: SideAssetRequestKey) -> Int {
        jobs[JobKey(origin: origin, request: requestKey)]?.waiters.count ?? 0
    }

    func waiterJobIndexCountForTesting() -> Int {
        waiterJobs.count
    }

    func recordedAdmissionsForTesting() -> [AdmissionForTesting] {
        admissionsForTesting
    }
#endif

    private func enqueue(
        waiterID: UUID,
        origin: SideAssetOrigin,
        owner: SideAssetOwner,
        requestKey: SideAssetRequestKey,
        operation: @escaping FetchOperation,
        isCancelled: Bool,
        continuation: CheckedContinuation<Data, any Error>
    ) {
        // The cancellation handler is installed before this closure executes. Its actor hop can
        // legitimately arrive before enqueue; checking the originating task here closes that
        // registration gap without retaining cancellation tombstones or risking a second resume.
        guard !isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }

        let key = JobKey(origin: origin, request: requestKey)
        let waiter = Waiter(id: waiterID, owner: owner, continuation: continuation)
        waiterJobs[waiterID] = key
        if var job = jobs[key] {
            job.waiters[waiterID] = waiter
            reassignQueueOwnerIfNeeded(&job)
            jobs[key] = job
        } else {
            jobs[key] = Job(
                key: key,
                operation: operation,
                waiters: [waiterID: waiter],
                status: .queued,
                queueOwner: owner
            )
            append(key, to: owner, at: origin)
        }
        schedule(origin)
    }

    private func append(_ key: JobKey, to owner: SideAssetOwner, at origin: SideAssetOrigin) {
        var state = origins[origin] ?? OriginState()
        if state.ownerQueues[owner] == nil {
            state.ownerQueues[owner] = []
            state.ownerOrder.append(owner)
        }
        state.ownerQueues[owner, default: []].append(key)
        origins[origin] = state
    }

    private func schedule(_ origin: SideAssetOrigin) {
        guard var state = origins[origin],
              state.activeCount < policy.maximumConcurrentRequests else { return }

        let now = clock.nowNanoseconds()
        if let lastStart = state.lastStartNanoseconds {
            let deadline = lastStart &+ policy.minimumStartIntervalNanoseconds
            if now < deadline {
                if !state.wakeScheduled {
                    state.wakeScheduled = true
                    origins[origin] = state
                    let clock = self.clock
                    Task {
                        try? await clock.sleepUntilNanoseconds(deadline)
                        self.wake(origin)
                    }
                }
                return
            }
        }

        guard let key = dequeueNext(from: &state), var job = jobs[key] else {
            origins[origin] = state
            return
        }
        state.activeCount += 1
        state.lastStartNanoseconds = now
        origins[origin] = state
        job.status = .running
#if DEBUG
        admissionsForTesting.append(.init(owner: job.queueOwner, timeNanoseconds: now))
#endif
        let operation = job.operation
        job.task = Task {
            let completion: Completion
            do { completion = .success(try await operation()) }
            catch { completion = .failure(error) }
            self.complete(key, with: completion)
        }
        jobs[key] = job

        // A zero-duration test policy can fill the cap synchronously; production pacing
        // normally schedules the next admission through the clock wake-up above.
        schedule(origin)
    }

    private func wake(_ origin: SideAssetOrigin) {
        guard var state = origins[origin] else { return }
        state.wakeScheduled = false
        origins[origin] = state
        schedule(origin)
    }

    private func dequeueNext(from state: inout OriginState) -> JobKey? {
        guard !state.ownerOrder.isEmpty else { return nil }
        let attempts = state.ownerOrder.count
        for _ in 0..<attempts {
            if state.nextOwnerIndex >= state.ownerOrder.count { state.nextOwnerIndex = 0 }
            let owner = state.ownerOrder[state.nextOwnerIndex]
            state.nextOwnerIndex = (state.nextOwnerIndex + 1) % state.ownerOrder.count
            guard !parkedOwners.contains(owner) else { continue }
            while var queue = state.ownerQueues[owner], !queue.isEmpty {
                let key = queue.removeFirst()
                state.ownerQueues[owner] = queue
                if let job = jobs[key], job.status == .queued, job.queueOwner == owner {
                    return key
                }
            }
        }
        return nil
    }

    private func complete(_ key: JobKey, with completion: Completion) {
        guard var job = jobs[key], var state = origins[key.origin] else { return }
        state.activeCount = max(0, state.activeCount - 1)
        origins[key.origin] = state

        if job.requeueIfCancelled,
           case .failure(let error) = completion,
           error is CancellationError,
           !job.waiters.isEmpty {
            job.status = .queued
            job.task = nil
            job.requeueIfCancelled = false
            reassignQueueOwnerIfNeeded(&job)
            jobs[key] = job
            append(key, to: job.queueOwner, at: key.origin)
        } else {
            jobs.removeValue(forKey: key)
            for waiter in job.waiters.values {
                waiterJobs.removeValue(forKey: waiter.id)
                switch completion {
                case .success(let data): waiter.continuation.resume(returning: data)
                case .failure(let error): waiter.continuation.resume(throwing: error)
                }
            }
        }
        compact(key.origin)
        schedule(key.origin)
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let key = waiterJobs.removeValue(forKey: waiterID),
              var job = jobs[key],
              let waiter = job.waiters.removeValue(forKey: waiterID) else { return }

        waiter.continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            if job.status == .running {
                job.task?.cancel()
                jobs[key] = job
            } else {
                jobs.removeValue(forKey: key)
            }
        } else {
            reassignQueueOwnerIfNeeded(&job)
            jobs[key] = job
        }
        compact(key.origin)
        schedule(key.origin)
    }

    private func allWaitersParked(_ job: Job) -> Bool {
        !job.waiters.isEmpty && job.waiters.values.allSatisfy { parkedOwners.contains($0.owner) }
    }

    private func reassignQueueOwnerIfNeeded(_ job: inout Job) {
        guard job.status == .queued, parkedOwners.contains(job.queueOwner),
              let activeOwner = job.waiters.values.first(where: { !parkedOwners.contains($0.owner) })?.owner else { return }
        job.queueOwner = activeOwner
        append(job.key, to: activeOwner, at: job.key.origin)
    }

    private func scheduleAllOrigins() {
        for origin in Array(origins.keys) { schedule(origin) }
    }

    /// Queue-owner reassignment deliberately leaves the old array entry inert so mutation stays
    /// simple. Compact at completion/cancellation boundaries to prevent those stale entries (and
    /// owner order slots) accumulating across long download sessions.
    private func compact(_ origin: SideAssetOrigin) {
        guard var state = origins[origin] else { return }
        for owner in state.ownerOrder {
            let live = (state.ownerQueues[owner] ?? []).filter { key in
                guard let job = jobs[key] else { return false }
                return job.status == .queued && job.queueOwner == owner
            }
            if live.isEmpty {
                state.ownerQueues.removeValue(forKey: owner)
            } else {
                state.ownerQueues[owner] = live
            }
        }
        state.ownerOrder.removeAll { state.ownerQueues[$0] == nil }
        state.nextOwnerIndex = state.ownerOrder.isEmpty
            ? 0
            : state.nextOwnerIndex % state.ownerOrder.count
        let hasJobs = jobs.keys.contains { $0.origin == origin }
        if !hasJobs && state.activeCount == 0 {
            origins.removeValue(forKey: origin)
        } else {
            origins[origin] = state
        }
    }

    private func compactAllOrigins() {
        for origin in Array(origins.keys) { compact(origin) }
    }
}

private enum SideAssetFetchError: Error {
    case invalidOrigin
    case httpStatus(Int)
    case emptyResponse
}

extension DownloadManager {
    nonisolated static func sideAssetOwner(for key: DownloadAttemptKey) -> SideAssetOwner {
        SideAssetOwner(rawValue: "\(key.ratingKey)\u{0}\(key.attemptID.rawValue)")
    }

    /// The one app-layer gateway for optional hydration payloads. Request identity is exact and
    /// process-local (method + URL + headers + body), so coalescing never crosses auth contexts.
    /// It is deliberately never logged or persisted because Plex URLs and MediaBrowser headers can
    /// carry credentials.
    func fetchOptionalSideAsset(_ request: URLRequest,
                                for key: DownloadAttemptKey) async throws -> Data {
        let owner = Self.sideAssetOwner(for: key)
        if isQueuePaused { await sideAssetFetchCoordinator.setParked(true, for: owner) }

        let policyRequest = Self.sideAssetRequest(applyingCellularPolicy: request)
        return try await sideAssetFetchCoordinator.fetch(request: policyRequest, owner: owner)
    }

    func setOptionalSideAssetHydrationParked(_ parked: Bool, for key: DownloadAttemptKey) {
        let coordinator = sideAssetFetchCoordinator
        let owner = Self.sideAssetOwner(for: key)
        Task { await coordinator.setParked(parked, for: owner) }
    }

    func cancelOptionalSideAssetHydration(for key: DownloadAttemptKey) {
        let coordinator = sideAssetFetchCoordinator
        let owner = Self.sideAssetOwner(for: key)
        Task { await coordinator.cancel(owner: owner) }
    }
}
