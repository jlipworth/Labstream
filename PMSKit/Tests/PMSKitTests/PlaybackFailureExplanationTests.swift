import Foundation
import Testing
@testable import PMSKit

struct PlaybackFailureExplanationTests {
    @Test(arguments: [-12889, -16830])
    func deadlinesDoNotBlameServerOrExposeCodes(code: Int) {
        let message = PlaybackFailureExplanation.message(for: NSError(domain: "CoreMediaErrorDomain", code: code))
        #expect(message == PlaybackFailureExplanation.deliveryTimeout)
        #expect(message?.contains(String(code)) == false)
        #expect(message?.contains("may") == true)
    }

    @Test(arguments: [-12906, -12910])
    func decoderFailuresExplainCompatibility(code: Int) {
        let underlying = NSError(domain: "NSOSStatusErrorDomain", code: code)
        let wrapper = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(PlaybackFailureExplanation.message(for: wrapper)?.contains("could not decode") == true)
    }

    @Test(arguments: [NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
                      NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                      NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed,
                      NSURLErrorServerCertificateUntrusted, NSURLErrorSecureConnectionFailed,
                      NSURLErrorUserAuthenticationRequired])
    func networkFailuresHaveSafeActions(code: Int) {
        let error = NSError(domain: NSURLErrorDomain, code: code,
                            userInfo: [NSLocalizedDescriptionKey: "secret-token https://private.example/media"])
        let message = PlaybackFailureExplanation.message(for: error)
        #expect(message != nil)
        #expect(message?.contains("secret-token") == false)
        #expect(message?.contains("private.example") == false)
    }

    @Test func unknownDomainsAndNilStayUnclassified() {
        #expect(PlaybackFailureExplanation.message(for: nil) == nil)
        #expect(PlaybackFailureExplanation.message(for: NSError(domain: "Unrelated", code: -12910)) == nil)
        #expect(PlaybackFailureExplanation.message(for: NSError(domain: "CoreMediaErrorDomain", code: -1)) == nil)
    }

    @Test func underlyingNetworkCauseOverridesGenericFormatFailure() {
        let error = NSError(domain: "AVFoundationErrorDomain", code: -11855,
                            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain,
                                                                    code: NSURLErrorNotConnectedToInternet)])
        #expect(PlaybackFailureExplanation.message(for: error)?.contains("connection was interrupted") == true)
    }
}
