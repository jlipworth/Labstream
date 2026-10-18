import Foundation
import Testing
@testable import PMSKit

struct P7DownloadContainerTests {
    @Test(arguments: ["mp4,m4v", " MP4 , M4V "])
    func firstContainerTokenIsUsedEverywhere(container: String) throws {
        let part = Part(id: 1, key: "/Items/fixture/media/source", container: container)
        let item = MediaItem(ratingKey: "fixture", title: "Fixture", type: "movie",
            media: [Media(id: 1, container: container, part: [part])])
        let selection = DownloadMediaSelectionPolicy.selection(item: item, mediaIndex: 0, partIndex: 0)
        let request = try JellyfinLibrary.downloadRequest(server: URL(string: "https://media.invalid")!,
            token: "", identity: JellyfinClientIdentity(client: "Fixture", device: "Fixture", deviceId: "fixture", version: "1"),
            itemId: "fixture", mediaSourceId: "source", container: container)
        do {
            #expect(OfflineDownloadDecision.isLocallyPlayableOriginal(part: part))
            #expect(request.url?.lastPathComponent == "stream.mp4")
            #expect(DownloadMediaSelectionPolicy.containerExtension(selection: selection) == "mp4")
        }
        #expect(DownloadMediaSelectionPolicy.containerExtension(selection: selection,
            existingRelativePath: "fixture.mov") == "mov")
    }

    @Test func unknownContainerAndFirstUnplayableTokenRetainPolicy() {
        #expect(!OfflineDownloadDecision.isLocallyPlayableOriginal(part: nil))
        #expect(!OfflineDownloadDecision.isLocallyPlayableOriginal(
            part: Part(id: 1, key: "/fixture", container: "mkv,mp4")))
    }
}
