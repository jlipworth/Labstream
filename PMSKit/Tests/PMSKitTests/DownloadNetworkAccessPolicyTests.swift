import Foundation
import Testing
@testable import PMSKit

// D5: the Downloads "Use cellular data" setting governs every costly network class — cellular,
// constrained (Low Data Mode) and expensive (for example a personal hotspot).
@Suite("Download network access policy")
struct DownloadNetworkAccessPolicyTests {
    @Test("The setting governs cellular, constrained and expensive networks", arguments: [false, true])
    func settingGovernsAllCostlyNetworks(allowsCostlyNetworks: Bool) throws {
        let base = URLRequest(url: try #require(URL(string: "https://example.invalid/media.mp4")))
        let request = DownloadNetworkAccessPolicy.applying(
            allowsCostlyNetworks: allowsCostlyNetworks, to: base)
        #expect(request.allowsCellularAccess == allowsCostlyNetworks)
        #expect(request.allowsConstrainedNetworkAccess == allowsCostlyNetworks)
        #expect(request.allowsExpensiveNetworkAccess == allowsCostlyNetworks)
        #expect(request.url == base.url)
    }
}
