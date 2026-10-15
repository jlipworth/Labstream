import Testing
@testable import PMSKit

@Suite("Download record identity")
struct DownloadRecordIdentityTests {

    @Test func recordKeysAreBackendNamespaced() {
        #expect(DownloadRecordIdentity.recordKey(for: "123", backend: .plex) == "123")
        #expect(DownloadRecordIdentity.recordKey(for: "abc", backend: .jellyfin) == "jellyfin:abc")
        #expect(DownloadRecordIdentity.recordKey(for: "xyz", backend: .emby) == "emby:xyz")
    }

    @Test func mediaBrowserRecordKeyConstructionIsIdempotent() {
        #expect(DownloadRecordIdentity.recordKey(for: "jellyfin:abc", backend: .jellyfin) == "jellyfin:abc")
        #expect(DownloadRecordIdentity.recordKey(for: "emby:xyz", backend: .emby) == "emby:xyz")
    }

    @Test func prefixBackendFallbackMatchesPersistedRows() {
        #expect(DownloadRecordIdentity.backendKind(forRecordKey: "99") == .plex)
        #expect(DownloadRecordIdentity.backendKind(forRecordKey: "jellyfin:item") == .jellyfin)
        #expect(DownloadRecordIdentity.backendKind(forRecordKey: "emby:item") == .emby)
    }

    @Test func itemIDExtractionIsBackendLocalAndIdempotent() {
        #expect(DownloadRecordIdentity.itemID(fromRecordKey: "99", backend: .plex) == "99")
        #expect(DownloadRecordIdentity.itemID(fromRecordKey: "jellyfin:item", backend: .jellyfin) == "item")
        #expect(DownloadRecordIdentity.itemID(fromRecordKey: "item", backend: .jellyfin) == "item")
        #expect(DownloadRecordIdentity.itemID(fromRecordKey: "emby:item", backend: .emby) == "item")
        #expect(DownloadRecordIdentity.itemID(fromRecordKey: "item", backend: .emby) == "item")
    }
}
