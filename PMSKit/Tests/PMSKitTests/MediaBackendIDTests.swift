import Foundation
import Testing
@testable import PMSKit

@Suite("Canonical media backend identifier")
struct MediaBackendIDTests {
    private let wireFixtures: [(MediaBackendID, String)] = [
        (.plex, "plex"),
        (.jellyfin, "jellyfin"),
        (.emby, "emby"),
    ]

    @Test("every canonical backend preserves its persisted raw value")
    func canonicalRawValueFixturesRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        #expect(MediaBackendID.allCases == wireFixtures.map(\.0))
        for (backend, rawValue) in wireFixtures {
            #expect(backend.rawValue == rawValue)
            #expect(String(decoding: try encoder.encode(backend), as: UTF8.self) == "\"\(rawValue)\"")
            #expect(try decoder.decode(MediaBackendID.self,
                                       from: Data("\"\(rawValue)\"".utf8)) == backend)
        }
    }

    @Test("legacy public names are exact source-compatible aliases")
    func compatibilityAliasesUseCanonicalIdentity() {
        for backend in MediaBackendID.allCases {
            let choice: MediaBackendChoice = backend
            let downloadKind: DownloadBackendKind = backend

            #expect(choice == backend)
            #expect(downloadKind == backend)
        }
    }

    @Test("legacy download metadata decodes every historical backend value")
    func legacyDownloadMetadataBackendFixturesDecode() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        for (backend, rawValue) in wireFixtures {
            let fixture = #"{"ratingKey":"legacy-item","title":"Legacy","backendKind":"\#(rawValue)"}"#
            let metadata = try decoder.decode(OfflineMetadata.self, from: Data(fixture.utf8))

            #expect(metadata.backendKind == backend)
            let encoded = try encoder.encode(metadata)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(object["backendKind"] as? String == rawValue)
        }
    }

    @Test("system-entry identifiers preserve every backend wire value")
    func systemEntryBackendFixturesRoundTrip() {
        for (backend, rawValue) in wireFixtures {
            let expected = "ls1|\(rawValue)|server.example.test|opaque|item"
            let route = BackendScopedMediaID(backend: backend,
                                             serverNamespace: "server.example.test",
                                             ratingKey: "opaque|item")

            #expect(route.identifier == expected)
            #expect(BackendScopedMediaID(systemIdentifier: expected) == route)
        }
    }
}
