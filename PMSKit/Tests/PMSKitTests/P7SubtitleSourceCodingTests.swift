import Foundation
import Testing
@testable import PMSKit

struct P7SubtitleSourceCodingTests {
    @Test func independentSubtitleOriginSurvivesMetadataRoundTrip() throws {
        let original = OfflineMetadata(ratingKey: "fixture", title: "Fixture", type: "movie",
            backendKind: .emby, mediaSourceID: "output-c")
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["textSubtitleSourceMediaSourceID"] = "source-s"
        let reloaded = try JSONDecoder().decode(OfflineMetadata.self,
            from: JSONSerialization.data(withJSONObject: object))
        let saved = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(reloaded)) as? [String: Any])
        #expect(reloaded.mediaSourceID == "output-c")
        do {
            #expect(saved["textSubtitleSourceMediaSourceID"] as? String == "source-s")
        }
        // Existing v5 rows without the future optional field still decode and keep output identity.
        #expect(try JSONDecoder().decode(OfflineMetadata.self, from: encoded).mediaSourceID == "output-c")
    }
    @Test func optionalFieldIsV5CompatibleAndSurvivesHandoffMerge() throws {
        var old = OfflineMetadata(ratingKey: "fixture", title: "Fixture", type: "movie",
            backendKind: .emby, mediaSourceID: "source-s")
        let oldBytes = try JSONEncoder().encode(old)
        #expect(try JSONDecoder().decode(OfflineMetadata.self, from: oldBytes)
            .textSubtitleSourceMediaSourceID == nil)
        var object = try #require(JSONSerialization.jsonObject(with: oldBytes) as? [String: Any])
        object["futureV5Field"] = ["ignored": true]
        #expect(try JSONDecoder().decode(OfflineMetadata.self,
            from: JSONSerialization.data(withJSONObject: object)).mediaSourceID == "source-s")
        old.textSubtitleSourceMediaSourceID = "source-s"
        var handoff = OfflineMetadata(ratingKey: "fixture", title: "Fixture", type: "movie",
            backendKind: .emby, mediaSourceID: "output-c")
        handoff.preserveCachedSideAssets(from: old)
        let reloaded = try JSONDecoder().decode(OfflineMetadata.self, from: JSONEncoder().encode(handoff))
        #expect(reloaded.mediaSourceID == "output-c")
        #expect(reloaded.textSubtitleSourceMediaSourceID == "source-s")
        // Old readers consume their known v5 scalars and ignore the additive field.
        struct OldReader: Decodable { let mediaSourceID: String? }
        #expect(try JSONDecoder().decode(OldReader.self, from: JSONEncoder().encode(handoff))
            .mediaSourceID == "output-c")
    }

}
