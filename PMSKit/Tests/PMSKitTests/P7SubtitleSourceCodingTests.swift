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
        withKnownIssue("P7 red pin: 08-coding") {
            #expect(saved["textSubtitleSourceMediaSourceID"] as? String == "source-s")
        }
        // Existing v5 rows without the future optional field still decode and keep output identity.
        #expect(try JSONDecoder().decode(OfflineMetadata.self, from: encoded).mediaSourceID == "output-c")
    }
}
