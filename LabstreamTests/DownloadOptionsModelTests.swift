#if !os(tvOS)
import Testing
@testable import Labstream

struct DownloadOptionsModelTests {
    @Test func plexExistingVersionResolvesItsOwnMediaAndFirstPart() throws {
        var model = DownloadOptionsModel()
        model.selection = .existingVersion(3)
        let selection = try #require(model.resolvedSelection(
            baseMediaIndex: 1, basePartIndex: 2, audioStreamIndex: 9))
        #expect(selection.intent.choice == .existingVersion)
        #expect(selection.intent.audioStreamIndex == nil)
        #expect(selection.mediaIndex == 3)
        #expect(selection.partIndex == 0)
        #expect(selection.mediaSourceIDOverride == nil)
    }

    @Test(arguments: [42, nil] as [Int?])
    func embyExistingVersionCarriesExactSourceAndReportedSize(sizeBytes: Int?) throws {
        var model = DownloadOptionsModel()
        model.selection = .embyExistingVersion(mediaSourceId: "source-b", sizeBytes: sizeBytes)
        let selection = try #require(model.resolvedSelection(
            baseMediaIndex: 1, basePartIndex: 2, audioStreamIndex: 9))
        #expect(selection.intent.choice == .existingVersion)
        #expect(selection.mediaSourceIDOverride == "source-b")
        // An unknown size stays explicitly unknown rather than collapsing to a default.
        #expect(selection.sizing == .reported(sizeBytes))
    }

    @Test func remuxKeepsSelectedAudioAndSourceCoordinates() throws {
        var model = DownloadOptionsModel()
        model.selection = .optimizeCompatible
        let selection = try #require(model.resolvedSelection(
            baseMediaIndex: 4, basePartIndex: 5, audioStreamIndex: 6))
        #expect(selection.intent.choice == .optimizeCompatible)
        #expect(selection.intent.audioStreamIndex == 6)
        #expect(selection.mediaIndex == 4)
        #expect(selection.partIndex == 5)
    }
}
#endif
