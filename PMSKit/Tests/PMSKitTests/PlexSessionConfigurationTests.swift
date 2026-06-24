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
