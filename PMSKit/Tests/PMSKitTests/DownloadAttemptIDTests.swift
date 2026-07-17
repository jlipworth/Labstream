import Foundation
import Testing
@testable import PMSKit

@Suite("Download attempt identity")
struct DownloadAttemptIDTests {
    @Test("Preserves arbitrary nonempty legacy strings")
    func preservesLegacyStrings() throws {
        let legacy = "attempt-777/legacy:value"
        let attemptID = try #require(DownloadAttemptID(rawValue: legacy))

        #expect(attemptID.rawValue == legacy)
        #expect(DownloadAttemptID(rawValue: "") == nil)
        #expect(try JSONEncoder().encode(attemptID) == JSONEncoder().encode(legacy))
        #expect(try JSONDecoder().decode(DownloadAttemptID.self, from: JSONEncoder().encode(legacy))
                == attemptID)
    }

    @Test("Rejects an empty persisted token")
    func rejectsEmptyDecode() throws {
        let encoded = try JSONEncoder().encode("")
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DownloadAttemptID.self, from: encoded)
        }
    }

    @Test("UUID factory is deterministic when supplied a UUID")
    func uuidFactory() throws {
        let uuid = try #require(UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678"))
        #expect(DownloadAttemptID(uuid: uuid).rawValue == "12345678-1234-5678-9ABC-DEF012345678")
        #expect(!DownloadAttemptID.generated().rawValue.isEmpty)
    }

    @Test("Attempt keys distinguish reused rating keys")
    func compoundKey() throws {
        let first = DownloadAttemptKey(
            ratingKey: "plex:item",
            attemptID: try #require(DownloadAttemptID(rawValue: "attempt-A")))
        let second = DownloadAttemptKey(
            ratingKey: "plex:item",
            attemptID: try #require(DownloadAttemptID(rawValue: "attempt-B")))

        #expect(first != second)
        #expect(Set([first, second]).count == 2)
    }

    @Test("Download record round-trips top-level ownership and decodes legacy absence")
    func recordCoding() throws {
        let attemptID = try #require(DownloadAttemptID(rawValue: "legacy-arbitrary-token"))
        let record = DownloadRecord(
            ratingKey: "jellyfin:item",
            attemptID: attemptID,
            title: "Item",
            localURL: URL(fileURLWithPath: "/tmp/item.mp4"))
        let encoded = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(DownloadRecord.self, from: encoded).attemptID == attemptID)

        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "attemptID")
        let legacyData = try JSONSerialization.data(withJSONObject: object)
        #expect(try JSONDecoder().decode(DownloadRecord.self, from: legacyData).attemptID == nil)
    }
}
