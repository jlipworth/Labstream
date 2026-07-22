import CryptoKit
import Foundation
import ImageIO
import SwiftUI

enum ArtworkPurpose: String, Hashable, Sendable {
    /// Ordinary in-app poster, cover, or backdrop presentation through `PosterImage`.
    case poster
}

enum ArtworkPriority: Int, Comparable, Sendable {
    case background = 0
    case utility = 1
    case visible = 2

    static func < (lhs: ArtworkPriority, rhs: ArtworkPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    fileprivate var taskPriority: TaskPriority {
        switch self {
        case .background: .background
        case .utility: .utility
        case .visible: .userInitiated
        }
    }
}

/// Token-free SwiftUI task identity for one authenticated artwork source.
///
/// The source is represented by a SHA-256 digest rather than by its path or request URL. Plex
/// request URLs contain the server token, and Jellyfin/Emby requests carry credentials in their
/// headers, so neither may participate in view identity, logs, or debug output.
struct ArtworkTaskIdentity: Hashable,
                            Sendable,
                            CustomStringConvertible,
                            CustomDebugStringConvertible,
                            CustomReflectable {
    let backend: MediaBackendKind
    let authority: ArtworkAuthority
    let purpose: ArtworkPurpose
    let pixelWidth: Int
    let pixelHeight: Int
    private let sourceDigest: Data

    init(backend: MediaBackendKind,
         authority: ArtworkAuthority,
         purpose: ArtworkPurpose,
         sourceDigest: Data,
         pixelWidth: Int,
         pixelHeight: Int) {
        self.backend = backend
        self.authority = authority
        self.purpose = purpose
        self.sourceDigest = sourceDigest
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    var description: String {
        "ArtworkTaskIdentity(backend: \(backend.rawValue), authority: <opaque>, purpose: \(purpose.rawValue), source: <redacted>, pixels: \(pixelWidth)x\(pixelHeight))"
    }

    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self,
               children: [
                   "backend": backend,
                   "authority": "<opaque>",
                   "purpose": purpose,
                   "source": "<redacted>",
                   "pixelWidth": pixelWidth,
                   "pixelHeight": pixelHeight,
               ],
               displayStyle: .struct)
    }
}

/// Opaque ownership boundary for artwork bytes. Remote requests are fenced by the exact
/// authenticated browse session; local files are fenced by their persisted owner plus a
/// monotonic content generation. Neither representation exposes credentials or file paths.
enum ArtworkAuthority: Hashable,
                       Sendable,
                       CustomStringConvertible,
                       CustomDebugStringConvertible,
                       CustomReflectable {
    case authenticated(BrowseSessionAuthority)
    case local(ArtworkLocalAuthority)

    var description: String { "ArtworkAuthority(<opaque>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["authority": "<opaque>"], displayStyle: .enum)
    }
}

struct ArtworkLocalAuthority: Hashable,
                              Sendable,
                              CustomStringConvertible,
                              CustomDebugStringConvertible,
                              CustomReflectable {
    private let digest: Data

    init(ownerData: Data, generation: UInt64) {
        var material = Data("labstream-local-artwork-owner-v1\0".utf8)
        material.append(ownerData)
        var generation = generation.bigEndian
        withUnsafeBytes(of: &generation) { material.append(contentsOf: $0) }
        digest = Data(SHA256.hash(data: material))
    }

    var description: String { "ArtworkLocalAuthority(<opaque>)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["authority": "<opaque>"], displayStyle: .struct)
    }
}

/// Token-free admission identity for one physical URL origin. It is derived from the canonical
/// scheme/host/port tuple and stored only as a digest, so reauthentication, backend changes, and
/// explicit default ports cannot bypass the same server's concurrency ceiling and a hostname never
/// becomes loggable pipeline identity.
private struct ArtworkOriginIdentity: Hashable, Sendable {
    let digest: Data
}

/// One resolved, authenticated artwork request.
///
/// The URLRequest is deliberately private: callers can compare the token-free task identity and
/// execute the descriptor through `ArtworkPipeline`, but cannot accidentally log a Plex token or
/// Jellyfin/Emby authorization header. Custom reflection is essential here: Swift's default
/// `dump`/`Mirror` would otherwise expose private request storage despite redacted descriptions.
struct ArtworkRequestDescriptor: Sendable,
                                 CustomStringConvertible,
                                 CustomDebugStringConvertible,
                                 CustomReflectable {
    let taskIdentity: ArtworkTaskIdentity
    var backend: MediaBackendKind { taskIdentity.backend }
    fileprivate let origin: ArtworkOriginIdentity
    private enum Source: Sendable {
        case remote(URLRequest)
        case localFile(URL)
    }

    private let source: Source

    init(taskIdentity: ArtworkTaskIdentity,
         request: URLRequest) {
        self.taskIdentity = taskIdentity
        var nonpersistentRequest = request
        nonpersistentRequest.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        source = .remote(nonpersistentRequest)
        let url = request.url
        let scheme = url?.scheme?.lowercased() ?? "unknown"
        let host = url?.host?.lowercased() ?? "unknown"
        let defaultPort: Int? = switch scheme {
        case "http": 80
        case "https": 443
        default: nil
        }
        let port = url?.port ?? defaultPort
        let rawOrigin = "\(scheme)|\(host)|\(port.map(String.init) ?? "default")"
        origin = ArtworkOriginIdentity(digest: Data(SHA256.hash(data: Data(rawOrigin.utf8))))
    }

    /// Construct a first-class local-file request. `ownerData` must come from persisted row
    /// ownership (never the active AppModel/session), while `generation` must advance whenever
    /// the file's contents are replaced even if its path and byte count remain unchanged.
    static func localFile(_ fileURL: URL,
                          backend: MediaBackendKind,
                          ownerData: Data,
                          generation: UInt64,
                          purpose: ArtworkPurpose = .poster,
                          pixelWidth: Int,
                          pixelHeight: Int) -> ArtworkRequestDescriptor? {
        guard fileURL.isFileURL,
              !ownerData.isEmpty,
              pixelWidth > 0,
              pixelHeight > 0 else { return nil }
        let identity = ArtworkTaskIdentity(
            backend: backend,
            authority: .local(ArtworkLocalAuthority(ownerData: ownerData,
                                                     generation: generation)),
            purpose: purpose,
            sourceDigest: Data(SHA256.hash(data: Data(fileURL.standardizedFileURL.path.utf8))),
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight)
        return ArtworkRequestDescriptor(taskIdentity: identity, localFileURL: fileURL)
    }

    private init(taskIdentity: ArtworkTaskIdentity, localFileURL: URL) {
        self.taskIdentity = taskIdentity
        source = .localFile(localFileURL)
        // All local artwork shares one admission origin so a long offline library cannot create
        // unbounded concurrent disk reads merely by using distinct file URLs.
        origin = ArtworkOriginIdentity(digest: Data(SHA256.hash(
            data: Data("labstream-local-artwork-origin-v1".utf8))))
    }

    var description: String { "ArtworkRequestDescriptor(\(taskIdentity))" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self,
               children: [
                   "taskIdentity": taskIdentity,
                   "backend": backend,
               ],
               displayStyle: .struct)
    }

    fileprivate func remoteData(using session: URLSession) async throws -> (Data, URLResponse) {
        guard case let .remote(request) = source else {
            throw ArtworkPipelineError.invalidResponse
        }
        return try await session.data(for: request)
    }

    fileprivate func data(
        using remoteTransport: ArtworkPipeline.Transport
    ) async throws -> (Data, URLResponse) {
        switch source {
        case .remote:
            return try await remoteTransport(self)
        case let .localFile(fileURL):
            do {
                try Task.checkCancellation()
                let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
                try Task.checkCancellation()
                let response = HTTPURLResponse(
                    url: URL(string: "https://local-artwork.invalid/image")!,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: nil)!
                return (data, response)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // File-system errors can contain the absolute path. Normalize them before they
                // cross the detached flight boundary.
                throw ArtworkPipelineError.transportFailure(code: nil)
            }
        }
    }

    #if DEBUG || PERFORMANCE_AUDIT
    fileprivate var uncachedDelivery: ArtworkDeliveryProvenance {
        switch source {
        case .remote: .networkDecode
        case .localFile: .localFile
        }
    }
    #endif
}

#if DEBUG || PERFORMANCE_AUDIT
enum ArtworkDeliveryProvenance: String, CaseIterable, Sendable {
    case networkDecode = "network_decode"
    case compressedCacheDecode = "compressed_cache_decode"
    case decodedCache = "decoded_cache"
    case inFlightJoin = "inflight_join"
    case localFile = "local_file"
}
#endif

struct ArtworkPipelineResponse: Sendable,
                                CustomStringConvertible,
                                CustomDebugStringConvertible,
                                CustomReflectable {
    let image: DecodedImage
    /// Original encoded bytes retained only for system AVMetadataItem artwork publication.
    let encodedData: Data
    /// ImageIO uniform type identifier for the original bytes (for example public.jpeg/png).
    let encodedTypeIdentifier: String?
    let byteCount: Int
    let statusCode: Int
    #if DEBUG || PERFORMANCE_AUDIT
    let delivery: ArtworkDeliveryProvenance
    #endif

    var description: String {
        #if DEBUG || PERFORMANCE_AUDIT
        "ArtworkPipelineResponse(bytes: \(byteCount), status: \(statusCode), type: \(encodedTypeIdentifier ?? "unknown"), delivery: \(delivery.rawValue), image: <opaque>, encodedData: <redacted>)"
        #else
        "ArtworkPipelineResponse(bytes: \(byteCount), status: \(statusCode), type: \(encodedTypeIdentifier ?? "unknown"), image: <opaque>, encodedData: <redacted>)"
        #endif
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        #if DEBUG || PERFORMANCE_AUDIT
        Mirror(self,
               children: [
                   "byteCount": byteCount,
                   "statusCode": statusCode,
                   "delivery": delivery.rawValue,
                   "encodedTypeIdentifier": encodedTypeIdentifier ?? "unknown",
                   "image": "<opaque>",
                   "encodedData": "<redacted>",
               ],
               displayStyle: .struct)
        #else
        Mirror(self,
               children: [
                   "byteCount": byteCount,
                   "statusCode": statusCode,
                   "encodedTypeIdentifier": encodedTypeIdentifier ?? "unknown",
                   "image": "<opaque>",
                   "encodedData": "<redacted>",
               ],
               displayStyle: .struct)
        #endif
    }

    #if DEBUG || PERFORMANCE_AUDIT
    fileprivate func withDelivery(_ delivery: ArtworkDeliveryProvenance) -> ArtworkPipelineResponse {
        ArtworkPipelineResponse(image: image,
                                encodedData: encodedData,
                                encodedTypeIdentifier: encodedTypeIdentifier,
                                byteCount: byteCount,
                                statusCode: statusCode,
                                delivery: delivery)
    }
    #endif
}

enum ArtworkPipelineError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case invalidImage
    /// Token-free Foundation transport category. The integer is a `URLError.Code.rawValue`, or
    /// nil for a non-Foundation transport failure; the original error is never allowed to escape
    /// because its userInfo may contain a credential-bearing Plex URL.
    case transportFailure(code: Int?)

    /// PosterImage retries transient transport/server/decode failures but does not hammer a server
    /// for a definitive client response. Only this class enters the short-lived negative cache.
    var isDefinitiveClientFailure: Bool {
        guard case let .httpStatus(status) = self else { return false }
        guard (400..<500).contains(status) else { return false }
        // These statuses describe retryable timing, concurrency, or throttling conditions rather
        // than a permanently invalid artwork source.
        return ![408, 409, 423, 424, 425, 429].contains(status)
    }
}

struct ArtworkPipelineConfiguration: Sendable {
    var maxConcurrentPerOrigin: Int = 4
    var compressedCostLimit: Int = 32 * 1_024 * 1_024
    var decodedCostLimit: Int = 128 * 1_024 * 1_024
    var negativeEntryLimit: Int = 256
    var negativeTTLNanoseconds: UInt64 = 30_000_000_000
    var nowNanoseconds: @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }

    fileprivate var normalized: ArtworkPipelineConfiguration {
        var copy = self
        copy.maxConcurrentPerOrigin = max(1, maxConcurrentPerOrigin)
        copy.compressedCostLimit = max(0, compressedCostLimit)
        copy.decodedCostLimit = max(0, decodedCostLimit)
        copy.negativeEntryLimit = max(0, negativeEntryLimit)
        return copy
    }
}

/// Construction policy for credential-bearing artwork transport. The app owns only an ephemeral
/// in-memory session: URLCache, cookies, and credential storage are disabled, and descriptors also
/// force a reload policy so Plex tokens in query strings are never written into a disk cache key.
enum ArtworkTransportPolicy {
    static func nonpersistentConfiguration(protocolClasses: [AnyClass]? = nil)
        -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }
}

/// App-lifetime facade over the actor-owned artwork scheduler and memory caches.
///
/// There is deliberately still no persistent cache. Exact requests join only when their backend,
/// opaque authority, purpose, source digest, and pixel dimensions match. Each waiter owns its own
/// cancellation; the shared operation is cancelled only after the last waiter leaves.
final class ArtworkPipeline: Sendable {
    typealias Transport = @Sendable (ArtworkRequestDescriptor) async throws -> (Data, URLResponse)
    private let core: ArtworkPipelineCore

    init(configuration: ArtworkPipelineConfiguration = ArtworkPipelineConfiguration()) {
        let session = URLSession(configuration: ArtworkTransportPolicy.nonpersistentConfiguration())
        core = ArtworkPipelineCore(configuration: configuration) { descriptor in
            try await descriptor.remoteData(using: session)
        }
    }

    #if DEBUG
    /// Internal deterministic seams for hosted tests. Release builds expose only the constructor
    /// that creates the privacy-safe nonpersistent session.
    init(configuration: ArtworkPipelineConfiguration = ArtworkPipelineConfiguration(),
         session: URLSession) {
        core = ArtworkPipelineCore(configuration: configuration) { descriptor in
            try await descriptor.remoteData(using: session)
        }
    }

    init(configuration: ArtworkPipelineConfiguration = ArtworkPipelineConfiguration(),
         transport: @escaping Transport) {
        core = ArtworkPipelineCore(configuration: configuration, transport: transport)
    }
    #endif

    func fetch(_ descriptor: ArtworkRequestDescriptor,
               priority: ArtworkPriority = .visible) async throws -> ArtworkPipelineResponse {
        try await core.fetch(descriptor, priority: priority)
    }

    /// Clear positive and negative memory state. Existing consumers are allowed to finish so a
    /// settings action does not strand visible posters, but their pre-clear bytes cannot repopulate
    /// either cache; the next appearance therefore performs a fresh request.
    func clear() async {
        await core.clear()
    }

    #if DEBUG
    /// Deterministic hosted-test observation; production scheduling never consults it.
    func waiterCountForTesting(_ identity: ArtworkTaskIdentity) async -> Int {
        await core.waiterCount(for: identity)
    }
    #endif
}

private actor ArtworkPipelineCore {
    private struct FlightKey: Hashable {
        let identity: ArtworkTaskIdentity
        let cacheEpoch: UInt64
    }

    private struct Waiter {
        let continuation: CheckedContinuation<ArtworkPipelineResponse, Error>
        #if DEBUG || PERFORMANCE_AUDIT
        let delivery: ArtworkDeliveryProvenance
        #endif
    }

    private final class Flight {
        enum State: Equatable { case queued, running }

        let id = UUID()
        let descriptor: ArtworkRequestDescriptor
        let identity: ArtworkTaskIdentity
        let origin: ArtworkOriginIdentity
        let sequence: UInt64
        let cacheEpoch: UInt64
        let compressedSeed: Data?
        var priority: ArtworkPriority
        var state: State = .queued
        var operation: Task<Void, Never>?
        var waiters: [UUID: Waiter] = [:]

        init(descriptor: ArtworkRequestDescriptor,
             priority: ArtworkPriority,
             sequence: UInt64,
             cacheEpoch: UInt64,
             compressedSeed: Data?) {
            self.descriptor = descriptor
            identity = descriptor.taskIdentity
            origin = descriptor.origin
            self.priority = priority
            self.sequence = sequence
            self.cacheEpoch = cacheEpoch
            self.compressedSeed = compressedSeed
        }
    }

    private struct Loaded: Sendable {
        let response: ArtworkPipelineResponse
        let compressedData: Data
    }

    private enum Outcome: Sendable {
        case success(Loaded)
        case failure(ArtworkPipelineError)
        case cancelled
    }

    private struct Negative: Sendable {
        let error: ArtworkPipelineError
        let expiresAt: UInt64
    }

    private let configuration: ArtworkPipelineConfiguration
    private let transport: ArtworkPipeline.Transport
    private var decodedCache: CostBoundedLRU<ArtworkTaskIdentity, ArtworkPipelineResponse>
    private var compressedCache: CostBoundedLRU<ArtworkTaskIdentity, Data>
    private var negativeCache: CostBoundedLRU<ArtworkTaskIdentity, Negative>
    private var flights: [FlightKey: Flight] = [:]
    private var runningOrigins: [UUID: ArtworkOriginIdentity] = [:]
    private var activeByOrigin: [ArtworkOriginIdentity: Int] = [:]
    private var nextSequence: UInt64 = 0
    private var cacheEpoch: UInt64 = 0

    init(configuration: ArtworkPipelineConfiguration,
         transport: @escaping ArtworkPipeline.Transport) {
        let normalized = configuration.normalized
        self.configuration = normalized
        self.transport = transport
        decodedCache = CostBoundedLRU(costLimit: normalized.decodedCostLimit)
        compressedCache = CostBoundedLRU(costLimit: normalized.compressedCostLimit)
        negativeCache = CostBoundedLRU(costLimit: normalized.negativeEntryLimit)
    }

    func fetch(_ descriptor: ArtworkRequestDescriptor,
               priority: ArtworkPriority) async throws -> ArtworkPipelineResponse {
        let waiterID = UUID()
        // Clear establishes a hard join boundary: consumers already waiting may finish, but a
        // post-clear consumer must not join their pre-clear bytes.
        let flightKey = FlightKey(identity: descriptor.taskIdentity, cacheEpoch: cacheEpoch)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                register(descriptor,
                         priority: priority,
                         waiterID: waiterID,
                         flightKey: flightKey,
                         continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, flightKey: flightKey) }
        }
    }

    func clear() {
        cacheEpoch &+= 1
        decodedCache.removeAll()
        compressedCache.removeAll()
        negativeCache.removeAll()
    }

    #if DEBUG
    func waiterCount(for identity: ArtworkTaskIdentity) -> Int {
        flights[FlightKey(identity: identity, cacheEpoch: cacheEpoch)]?.waiters.count ?? 0
    }
    #endif

    private func register(_ descriptor: ArtworkRequestDescriptor,
                          priority: ArtworkPriority,
                          waiterID: UUID,
                          flightKey: FlightKey,
                          continuation: CheckedContinuation<ArtworkPipelineResponse, Error>) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }

        let identity = descriptor.taskIdentity
        if let cached = decodedCache.value(for: identity) {
            #if DEBUG || PERFORMANCE_AUDIT
            continuation.resume(returning: cached.withDelivery(.decodedCache))
            #else
            continuation.resume(returning: cached)
            #endif
            return
        }

        if let negative = negativeCache.value(for: identity) {
            if negative.expiresAt > configuration.nowNanoseconds() {
                continuation.resume(throwing: negative.error)
                return
            }
            negativeCache.removeValue(for: identity)
        }

        if let flight = flights[flightKey] {
            flight.priority = max(flight.priority, priority)
            #if DEBUG || PERFORMANCE_AUDIT
            flight.waiters[waiterID] = Waiter(continuation: continuation,
                                              delivery: .inFlightJoin)
            #else
            flight.waiters[waiterID] = Waiter(continuation: continuation)
            #endif
            admit(origin: flight.origin)
            return
        }

        nextSequence &+= 1
        let flight = Flight(descriptor: descriptor,
                            priority: priority,
                            sequence: nextSequence,
                            cacheEpoch: cacheEpoch,
                            compressedSeed: compressedCache.value(for: identity))
        #if DEBUG || PERFORMANCE_AUDIT
        let delivery: ArtworkDeliveryProvenance = flight.compressedSeed == nil
        ? descriptor.uncachedDelivery
        : .compressedCacheDecode
        flight.waiters[waiterID] = Waiter(continuation: continuation, delivery: delivery)
        #else
        flight.waiters[waiterID] = Waiter(continuation: continuation)
        #endif
        flights[flightKey] = flight
        admit(origin: flight.origin)
    }

    private func cancelWaiter(_ waiterID: UUID, flightKey: FlightKey) {
        guard let flight = flights[flightKey],
              let waiter = flight.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        guard flight.waiters.isEmpty else { return }

        flights.removeValue(forKey: flightKey)
        if flight.state == .running {
            // Keep the origin slot until the operation actually unwinds. A cancellation-ignoring
            // transport must not let admitted wire work exceed the per-origin ceiling.
            flight.operation?.cancel()
        }
    }

    private func admit(origin: ArtworkOriginIdentity) {
        while activeByOrigin[origin, default: 0] < configuration.maxConcurrentPerOrigin,
              let flight = nextQueuedFlight(origin: origin) {
            flight.state = .running
            activeByOrigin[origin, default: 0] += 1
            runningOrigins[flight.id] = origin

            let transport = self.transport
            let descriptor = flight.descriptor
            let compressedSeed = flight.compressedSeed
            let flightID = flight.id
            let flightKey = FlightKey(identity: flight.identity, cacheEpoch: flight.cacheEpoch)
            let priority = flight.priority.taskPriority
            flight.operation = Task.detached(priority: priority) { [self] in
                let outcome: Outcome
                do {
                    outcome = .success(try await Self.load(descriptor: descriptor,
                                                           compressedSeed: compressedSeed,
                                                           transport: transport))
                } catch is CancellationError {
                    outcome = .cancelled
                } catch let error as ArtworkPipelineError {
                    outcome = .failure(error)
                } catch {
                    // All known work is normalized inside `load`; keep the detached-task boundary
                    // fail-closed if a future implementation accidentally throws a raw error.
                    outcome = .failure(.transportFailure(code: nil))
                }
                await complete(flightID: flightID,
                               flightKey: flightKey,
                               outcome: outcome)
            }
        }
    }

    private func nextQueuedFlight(origin: ArtworkOriginIdentity) -> Flight? {
        flights.values
            .filter { $0.origin == origin && $0.state == .queued && !$0.waiters.isEmpty }
            .max { lhs, rhs in
                if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
                return lhs.sequence > rhs.sequence
            }
    }

    private func complete(flightID: UUID,
                          flightKey: FlightKey,
                          outcome: Outcome) {
        guard let origin = runningOrigins.removeValue(forKey: flightID) else { return }
        activeByOrigin[origin] = max(0, activeByOrigin[origin, default: 1] - 1)
        if activeByOrigin[origin] == 0 { activeByOrigin.removeValue(forKey: origin) }

        guard let flight = flights[flightKey], flight.id == flightID else {
            admit(origin: origin)
            return
        }
        flights.removeValue(forKey: flightKey)
        let identity = flight.identity

        switch outcome {
        case let .success(loaded):
            if flight.cacheEpoch == cacheEpoch {
                compressedCache.insert(loaded.compressedData,
                                       for: identity,
                                       cost: loaded.compressedData.count)
                decodedCache.insert(loaded.response,
                                    for: identity,
                    cost: Self.decodedCost(loaded.response))
                negativeCache.removeValue(for: identity)
            }
            for waiter in flight.waiters.values {
                #if DEBUG || PERFORMANCE_AUDIT
                waiter.continuation.resume(returning: loaded.response.withDelivery(waiter.delivery))
                #else
                waiter.continuation.resume(returning: loaded.response)
                #endif
            }

        case let .failure(error):
            if flight.cacheEpoch == cacheEpoch,
               error.isDefinitiveClientFailure,
               configuration.negativeEntryLimit > 0,
               configuration.negativeTTLNanoseconds > 0 {
                let now = configuration.nowNanoseconds()
                let (expiry, overflow) = now.addingReportingOverflow(
                    configuration.negativeTTLNanoseconds)
                negativeCache.insert(Negative(error: error,
                                              expiresAt: overflow ? UInt64.max : expiry),
                                     for: identity,
                                     cost: 1)
            }
            for waiter in flight.waiters.values {
                waiter.continuation.resume(throwing: error)
            }

        case .cancelled:
            for waiter in flight.waiters.values {
                waiter.continuation.resume(throwing: CancellationError())
            }
        }

        admit(origin: origin)
    }

    private nonisolated static func load(
        descriptor: ArtworkRequestDescriptor,
        compressedSeed: Data?,
        transport: ArtworkPipeline.Transport
    ) async throws -> Loaded {
        try Task.checkCancellation()
        let data: Data
        if let compressedSeed {
            data = compressedSeed
        } else {
            let received: Data
            let response: URLResponse
            do {
                (received, response) = try await descriptor.data(using: transport)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError {
                throw ArtworkPipelineError.transportFailure(code: error.code.rawValue)
            } catch {
                throw ArtworkPipelineError.transportFailure(code: nil)
            }
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw ArtworkPipelineError.invalidResponse
            }
            guard response.statusCode == 200 else {
                throw ArtworkPipelineError.httpStatus(response.statusCode)
            }
            data = received
        }

        try Task.checkCancellation()
        guard let decoded = ArtworkImageDecoder.decode(data: data,
                                                       pixelWidth: descriptor.taskIdentity.pixelWidth,
                                                       pixelHeight: descriptor.taskIdentity.pixelHeight) else {
            throw ArtworkPipelineError.invalidImage
        }
        try Task.checkCancellation()
        #if DEBUG || PERFORMANCE_AUDIT
        let response = ArtworkPipelineResponse(image: decoded.image,
                                               encodedData: data,
                                               encodedTypeIdentifier: decoded.typeIdentifier,
                                               byteCount: data.count,
                                               statusCode: 200,
                                               delivery: descriptor.uncachedDelivery)
        #else
        let response = ArtworkPipelineResponse(image: decoded.image,
                                               encodedData: data,
                                               encodedTypeIdentifier: decoded.typeIdentifier,
                                               byteCount: data.count,
                                               statusCode: 200)
        #endif
        return Loaded(response: response,
                      compressedData: data)
    }

    private nonisolated static func decodedCost(_ response: ArtworkPipelineResponse) -> Int {
        let (pixelBytes, pixelOverflow) = response.image.cgImage.bytesPerRow
            .multipliedReportingOverflow(by: response.image.cgImage.height)
        guard !pixelOverflow else { return Int.max }
        let (total, totalOverflow) = pixelBytes.addingReportingOverflow(response.encodedData.count)
        return totalOverflow ? Int.max : max(1, total)
    }
}

private enum ArtworkImageDecoder {
    struct Result {
        let image: DecodedImage
        let typeIdentifier: String?
    }
    /// ImageIO thumbnailing both bounds peak decode work and eagerly materializes the pixels on the
    /// detached flight task. `CreateThumbnailWithTransform` applies EXIF orientation, so the
    /// resulting immutable CGImage is stored upright.
    nonisolated static func decode(data: Data,
                                   pixelWidth: Int,
                                   pixelHeight: Int) -> Result? {
        guard pixelWidth > 0, pixelHeight > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              rawWidth > 0, rawHeight > 0 else { return nil }

        let orientationRaw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
        let swapsAxes: Bool
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored: swapsAxes = true
        default: swapsAxes = false
        }
        let displayWidth = swapsAxes ? rawHeight : rawWidth
        let displayHeight = swapsAxes ? rawWidth : rawHeight
        let scale = min(1,
                        min(Double(pixelWidth) / displayWidth,
                            Double(pixelHeight) / displayHeight))
        let maxPixelSize = max(1, Int(ceil(max(displayWidth, displayHeight) * scale)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceShouldCache: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return Result(image: DecodedImage(cgImage: image, scale: 1, orientation: .up),
                      typeIdentifier: CGImageSourceGetType(source) as String?)
    }
}

private struct CostBoundedLRU<Key: Hashable, Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var access: UInt64
    }

    private let costLimit: Int
    private var entries: [Key: Entry] = [:]
    private var totalCost = 0
    private var nextAccess: UInt64 = 0

    init(costLimit: Int) {
        self.costLimit = max(0, costLimit)
    }

    mutating func value(for key: Key) -> Value? {
        guard var entry = entries[key] else { return nil }
        nextAccess &+= 1
        entry.access = nextAccess
        entries[key] = entry
        return entry.value
    }

    mutating func insert(_ value: Value, for key: Key, cost: Int) {
        if let existing = entries.removeValue(forKey: key) { totalCost -= existing.cost }
        guard costLimit > 0 else { return }
        let normalizedCost = max(1, cost)
        guard normalizedCost <= costLimit else {
            evictToLimit()
            return
        }
        nextAccess &+= 1
        entries[key] = Entry(value: value, cost: normalizedCost, access: nextAccess)
        totalCost += normalizedCost
        evictToLimit()
    }

    mutating func removeValue(for key: Key) {
        if let removed = entries.removeValue(forKey: key) { totalCost -= removed.cost }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        totalCost = 0
    }

    private mutating func evictToLimit() {
        while totalCost > costLimit,
              let victim = entries.min(by: { $0.value.access < $1.value.access })?.key {
            removeValue(for: victim)
        }
    }
}

private struct ArtworkPipelineEnvironmentKey: EnvironmentKey {
    static let defaultValue: ArtworkPipeline? = nil
}

extension EnvironmentValues {
    /// Optional by design so isolated previews and tests render the normal placeholder rather
    /// than crashing when they are not mounted below the authenticated app root.
    var artworkPipeline: ArtworkPipeline? {
        get { self[ArtworkPipelineEnvironmentKey.self] }
        set { self[ArtworkPipelineEnvironmentKey.self] = newValue }
    }
}
