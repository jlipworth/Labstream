import Testing
@testable import PMSKit

@Suite("Compatible-remux fallback disclosure")
struct DownloadCompatibleRemuxDisclosurePolicyTests {
    @Test("Only Emby displays the persistent Convert fallback disclosure")
    func backendScope() {
        #expect(DownloadCompatibleRemuxDisclosurePolicy.showsFallbackDisclosure(backend: .emby))
        #expect(!DownloadCompatibleRemuxDisclosurePolicy.showsFallbackDisclosure(backend: .jellyfin))
        #expect(!DownloadCompatibleRemuxDisclosurePolicy.showsFallbackDisclosure(backend: .plex))
    }

    @Test("Known above-1080p Emby sources require confirmation")
    func confirmationBoundary() {
        #expect(DownloadCompatibleRemuxDisclosurePolicy.requiresConfirmation(
            backend: .emby, sourceWidth: 3_840, sourceHeight: 2_160))
        #expect(DownloadCompatibleRemuxDisclosurePolicy.requiresConfirmation(
            backend: .emby, sourceWidth: 1_920, sourceHeight: 1_200))
        #expect(!DownloadCompatibleRemuxDisclosurePolicy.requiresConfirmation(
            backend: .emby, sourceWidth: 1_920, sourceHeight: 1_080))
        #expect(!DownloadCompatibleRemuxDisclosurePolicy.requiresConfirmation(
            backend: .emby, sourceWidth: nil, sourceHeight: nil))
        #expect(!DownloadCompatibleRemuxDisclosurePolicy.requiresConfirmation(
            backend: .jellyfin, sourceWidth: 3_840, sourceHeight: 2_160))
    }
}
