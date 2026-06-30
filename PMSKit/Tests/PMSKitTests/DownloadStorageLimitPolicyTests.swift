import Foundation
import Testing
@testable import PMSKit

@Suite("Download storage limit policy")
struct DownloadStorageLimitPolicyTests {
    @Test("Labels preserve configured caps and unlimited fallback")
    func labels() {
        #expect(DownloadStorageLimitPolicy.unlimited == 0)
        #expect(DownloadStorageLimitPolicy.label(bytes: 0) == "Unlimited")
        #expect(DownloadStorageLimitPolicy.label(bytes: 10 * 1_000_000_000) == "10 GB")
        #expect(DownloadStorageLimitPolicy.label(bytes: -1) == "Unlimited")
        #expect(DownloadStorageLimitPolicy.label(bytes: 12_345).contains("KB"))
    }

    @Test("Rejection message only appears when projected usage exceeds a positive cap")
    func rejectionGate() {
        #expect(DownloadStorageLimitPolicy.rejectionMessage(adding: nil,
                                                            currentBytes: 9_000_000_000,
                                                            limitBytes: 10_000_000_000) == nil)
        #expect(DownloadStorageLimitPolicy.rejectionMessage(adding: 2_000_000_000,
                                                            currentBytes: 9_000_000_000,
                                                            limitBytes: 0) == nil)
        #expect(DownloadStorageLimitPolicy.rejectionMessage(adding: 1_000_000_000,
                                                            currentBytes: 9_000_000_000,
                                                            limitBytes: 10_000_000_000) == nil)
        let message = DownloadStorageLimitPolicy.rejectionMessage(adding: 2_000_000_000,
                                                                  currentBytes: 9_000_000_000,
                                                                  limitBytes: 10_000_000_000)
        #expect(message?.contains("This download needs about") == true)
        #expect(message?.contains("10 GB") == true)
        #expect(message?.contains("Increase the limit") == true)
    }
}
