import Foundation
import Testing
@testable import Labstream

struct LabstreamLinksTests {
    @Test func publicLinksUseHTTPSAndTheSupportAddress() {
        #expect(LabstreamLinks.privacyPolicy.scheme == "https")
        #expect(LabstreamLinks.support.scheme == "https")
        #expect(LabstreamLinks.privacyPolicy.absoluteString.hasSuffix("/privacy/"))
        #expect(LabstreamLinks.support.absoluteString.hasSuffix("/support/"))
        #expect(LabstreamLinks.supportEmail.absoluteString == "mailto:support@labstream.app")
        #expect(LabstreamLinks.bugReport.query == "template=bug_report.yml")
    }

    @Test func displayStringDropsSchemeAndTrailingSlash() {
        #expect(LabstreamLinks.displayString(URL(string: "https://labstream.app/privacy/")!)
                == "labstream.app/privacy")
        #expect(LabstreamLinks.displayString(LabstreamLinks.supportEmail) == "support@labstream.app")
    }
}
