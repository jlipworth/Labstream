#if !os(tvOS)
import Foundation
import PMSKit
import Testing
@testable import Labstream

struct P7SubtitleSourceRecoveryTests {
    @Test func convertedOutputCannotReplaceOriginalSubtitleSource() throws {
        let source = Part(id: 1, key: "/Items/fixture/media/source-s", streams: [
            Stream(id: 7, streamType: StreamType.subtitle.rawValue, codec: "srt")])
        let converted = Part(id: 2, key: "/Items/fixture/media/output-c")
        var metadata = OfflineMetadata(ratingKey: "fixture", title: "Fixture", type: "movie",
            backendKind: .emby, mediaSourceID: "output-c")
        metadata.mediaIndex = 0
        metadata.partIndex = 0
        // Current v5 coding has no subtitle-origin identity. Preserve an unknown future field
        // in the fixture without adding it to the production persisted schema in P7.1.
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        json["textSubtitleSourceMediaSourceID"] = "source-s"
        let reloaded = try JSONDecoder().decode(OfflineMetadata.self,
            from: JSONSerialization.data(withJSONObject: json))
        let reordered = MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie", media: [
            Media(id: 2, part: [converted]), Media(id: 1, part: [source])])
        let selected = DownloadManager.subtitleRepairPart(item: reordered, metadata: reloaded)
        do {
            #expect(selected?.key == source.key)
            #expect(selected?.streams?.contains { $0.id == 7 } == true)
        }
    }
    @Test(arguments: [false, true])
    func missingOrAmbiguousOriginalNeverSelectsSibling(ambiguous: Bool) throws {
        let metadata = OfflineMetadata(ratingKey: "fixture", title: "Fixture", type: "movie",
            backendKind: .emby, mediaSourceID: "output-c")
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        json["textSubtitleSourceMediaSourceID"] = "source-s"
        let reloaded = try JSONDecoder().decode(OfflineMetadata.self,
            from: JSONSerialization.data(withJSONObject: json))
        let output = Media(id: 1, part: [Part(id: 1, key: "/Items/fixture/media/output-c")])
        let source = Media(id: 2, part: [Part(id: 2, key: "/Items/fixture/media/source-s")])
        let item = MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie",
            media: ambiguous ? [output, source, source] : [output])
        let selected = DownloadManager.subtitleRepairPart(item: item, metadata: reloaded)
        do { #expect(selected == nil) }
    }
}
#endif
