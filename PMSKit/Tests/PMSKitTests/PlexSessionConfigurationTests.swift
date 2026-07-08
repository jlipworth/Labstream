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
