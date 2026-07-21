import Testing
import Foundation
@testable import PMSKit

@Test func recoveryControlPlaneSessionUsesShortTimeouts() {
    let config = PlexSessionConfiguration.recoveryControlPlane(timeout: 4.5)

    #expect(config.timeoutIntervalForRequest == 4.5)
    #expect(config.timeoutIntervalForResource == 4.5)
}

@Test func recoveryControlPlaneSessionAvoidsSharedState() {
    let config = PlexSessionConfiguration.recoveryControlPlane(timeout: 5)

    #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(config.urlCache == nil)
    #expect(config.httpCookieStorage == nil)
    #expect(config.httpShouldSetCookies == false)
    #expect(config.httpCookieAcceptPolicy == .never)
}

// `waitsForConnectivity` is unavailable in swift-corelibs-foundation (Linux CI); this
// behaviour is asserted only on Apple platforms.
#if !canImport(FoundationNetworking)
@Test func recoveryControlPlaneSessionFailsFastInsteadOfWaitingForConnectivity() {
    let config = PlexSessionConfiguration.recoveryControlPlane(timeout: 5)

    #expect(config.waitsForConnectivity == false)
}
#endif

@Test func mediaUpstreamConfigIsEphemeralWithGenerousTimeout() {
    let config = PlexSessionConfiguration.mediaUpstream(timeout: 20)

    #expect(config.timeoutIntervalForRequest == 20)
    #expect(config.urlCache == nil)
    #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #if !canImport(FoundationNetworking)
    #expect(config.waitsForConnectivity == false)
    #endif
}

// The proxy is store-and-forward: a large segment flowing slowly must not be killed by the
// whole-transfer deadline while the wedge (request) timeout stays short. A resource timeout
// equal to the request timeout hard-502'd any proxied transfer over 20s.
@Test func mediaUpstreamResourceTimeoutBoundsWholeTransferGenerously() {
    let config = PlexSessionConfiguration.mediaUpstream(timeout: 20)

    #expect(config.timeoutIntervalForResource == 300)
    #expect(config.timeoutIntervalForResource > config.timeoutIntervalForRequest)

    let custom = PlexSessionConfiguration.mediaUpstream(timeout: 10, resourceTimeout: 120)
    #expect(custom.timeoutIntervalForRequest == 10)
    #expect(custom.timeoutIntervalForResource == 120)
}

#if canImport(Network)
/// Behavioral guard for the deadline authority used by both recovery control-plane calls and
/// media-proxy upstream calls. `URLRequest(url:)` carries Foundation's 60-second default, so the
/// important fact is that the shorter session configuration still wins on a real silent socket.
@Test func configuredRequestDeadlinesWinOverURLRequestDefaultOnSilentTransport() async throws {
    let release = HangingTransportRelease()
    let origin = LoopbackOrigin()
    let port = try await origin.start { _ in
        await release.wait()
        return HTTPResponse(status: 200, reason: "OK", headers: [], body: Data())
    }
    defer {
        release.resume()
        origin.stop()
    }

    let url = URL(string: "http://127.0.0.1:\(port)/hang")!
    let request = URLRequest(url: url)
    #expect(request.timeoutInterval == 60)

    let configurations = [
        PlexSessionConfiguration.recoveryControlPlane(timeout: 0.2),
        PlexSessionConfiguration.mediaUpstream(timeout: 0.2, resourceTimeout: 5),
    ]
    for configuration in configurations {
        let result = await requestOutcome(
            request,
            using: URLSession(configuration: configuration),
            watchdogNanoseconds: 2_000_000_000)
        #expect(result == .timedOut)
    }
}

private enum RequestOutcome: Equatable, Sendable {
    case timedOut
    case watchdog
    case otherURLError(URLError.Code)
    case unexpectedSuccess
}

private func requestOutcome(_ request: URLRequest,
                            using session: URLSession,
                            watchdogNanoseconds: UInt64) async -> RequestOutcome {
    defer { session.invalidateAndCancel() }
    return await withTaskGroup(of: RequestOutcome.self) { group in
        group.addTask {
            do {
                _ = try await session.data(for: request)
                return .unexpectedSuccess
            } catch let error as URLError {
                return error.code == .timedOut ? .timedOut : .otherURLError(error.code)
            } catch {
                return .otherURLError(.unknown)
            }
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: watchdogNanoseconds)
            return Task.isCancelled ? .otherURLError(.cancelled) : .watchdog
        }
        let first = await group.next() ?? .watchdog
        group.cancelAll()
        return first
    }
}

private final class HangingTransportRelease: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isReleased {
                lock.unlock()
                continuation.resume()
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func resume() {
        lock.lock()
        isReleased = true
        let pending = continuations
        continuations.removeAll()
        lock.unlock()
        for continuation in pending {
            continuation.resume()
        }
    }
}
#endif
