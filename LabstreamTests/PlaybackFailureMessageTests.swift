import Foundation
import Testing
@testable import Labstream

@MainActor
struct PlaybackFailureMessageTests {
    @Test func decoderErrorUsesPlainLanguageAndClearResets() {
        let state = PlaybackError()
        state.set(NSError(domain: "CoreMediaErrorDomain", code: -12910))
        #expect(state.isFailed)
        #expect(state.message?.contains("could not decode") == true)
        #expect(state.message?.contains("12910") == false)
        #expect(state.message?.contains("LS-PB-999") == true)
        state.clear()
        #expect(!state.isFailed)
        #expect(state.message == nil)
    }

    @Test func unknownErrorDoesNotLeakDescription() {
        let state = PlaybackError()
        state.set(NSError(domain: "Unrecognized", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "private-server/token"]))
        #expect(state.message?.contains("app diagnostics") == true)
        #expect(state.message?.contains("private-server") == false)
    }

    @Test func deadlineExplanationDoesNotExposeCodesOrPromiseRetrySuccess() {
        let message = HLSStartupDeadlinePolicy.failureMessage(errorLogCodes: [-12889, -16830])
        #expect(!message.contains("12889"))
        #expect(!message.contains("usually ready"))
        #expect(message.contains("may"))
    }

    @Test func consentUsesTypedSafeExplanation() {
        let state = PlaybackError()
        state.set(NSError(domain: "Labstream.Playback", code: -290,
                          userInfo: [NSLocalizedDescriptionKey: "Video transcoding was not authorized."]))
        #expect(state.failure?.code == .consentRequired)
        #expect(state.message?.contains("requires your permission") == true)
        #expect(state.message?.contains("LS-PB-005") == true)
    }

    @Test func typedHTTPFailureWinsOverUnderlyingDecoderExplanation() {
        let state = PlaybackError()
        state.set(NSError(domain: "HTTPErrorDomain", code: 503, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12910)]))
        #expect(state.failure?.code == .serverHTTP)
        #expect(state.message?.contains("LS-PB-002") == true)
        #expect(state.message?.contains("could not decode") == false)
    }

    @Test func unrecognizedAuthoredDomainDoesNotBypassClosedVocabulary() {
        let state = PlaybackError()
        state.set(NSError(domain: "Labstream.Playback", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "private-server/token"]))
        #expect(state.failure?.code == .unknown)
        #expect(state.message?.contains("private-server") == false)
        #expect(state.message?.contains("LS-PB-999") == true)
    }

}
