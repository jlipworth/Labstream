#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

@Suite("P6 opaque manual resume", .serialized)
struct P6OpaqueResumeTests {
    @Test("Opaque Resume reaches network admission; a Pause during task creation wins", arguments: [false, true])
    func pauseThenResume(pauseDuringCreation: Bool) async throws {
        let fixture = try P6Fixture()
        let store = fixture.store()
        let key = try fixture.seed(store)
        let session = BackgroundDownloadSession(store: store, protocolClasses: [P6OpaqueResumeURLProtocol.self])
        defer { session.invalidateInjectedSessionForTesting() }
        _ = await withCheckedContinuation { continuation in
            session.activateCurrentStore { continuation.resume(returning: $0) }
        }
        let request = URLRequest(url: URL(string: "https://example.invalid/opaque")!)
        try session.start(ratingKey: key.ratingKey, with: request, byteRangeCheckpoint: false)
        try #require(await p6Signal(P6OpaqueResumeURLProtocol.started))
        let paused = DispatchSemaphore(value: 0)
        session.onChange = { if store.record(for: key)?.status == .paused { paused.signal() } }
        session.pause(ratingKey: key.ratingKey)
        try #require(await p6Signal(paused))
        // CFNetwork blob decoding is outside this pin. The factory returns a REAL suspended
        // download task, which must pass the production persistence/halt/generation admission.
        session.opaqueResumeTaskForTesting = { [weak session] transport, _ in
            if pauseDuringCreation { session?.pause(ratingKey: key.ratingKey) }
            return transport.downloadTask(with: request)
        }
        #expect(session.resume(ratingKey: key.ratingKey, resumeData: Data([1])) == !pauseDuringCreation)
        if !pauseDuringCreation { #expect(await p6Signal(P6OpaqueResumeURLProtocol.started)) }
    }
}

private final class P6OpaqueResumeURLProtocol: URLProtocol, @unchecked Sendable {
    static let started = DispatchSemaphore(value: 0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.started.signal() }
    override func stopLoading() {}
}
#endif
